import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Turns captured frames into canvas frames before they are encoded:
///   - a capture with a different aspect ratio than the canvas (a 21:9 WoW
///     window on a 16:9 canvas) is centered with even black bars, as OBS
///     "fit to canvas" did;
///   - the chat overlay image is drawn on top (libobs did this with an image
///     source in the scene).
/// Frames that already match the canvas pass through untouched when there is
/// no overlay. Rendering runs on the GPU through Core Image into pooled
/// buffers.
final class FrameCompositor {
  private let lock = NSLock()
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

  /// Guarded by `lock`.
  private var canvas = (width: 0, height: 0)
  private var placed: CIImage?
  private var applied: (config: OverlayConfig?, width: Int, height: Int)?

  /// The decoded image, so moving or scaling it does not reread the file.
  /// Cleared when the overlay is turned off, so turning it back on picks
  /// up an edited file.
  private var loaded: (path: String, image: CIImage)?

  /// Only touched from the frame pacer's queue.
  private var pool: CVPixelBufferPool?
  private var poolFormat: (width: Int, height: Int, type: OSType)?

  /// Set the canvas and the overlay. A no-op if nothing changed. Throws when
  /// the overlay image cannot be read; the overlay is then off until the
  /// next change.
  func update(_ config: OverlayConfig?, canvasWidth: Int, canvasHeight: Int) throws {
    lock.lock()
    defer { lock.unlock() }

    canvas = (canvasWidth, canvasHeight)

    if let applied, applied.config == config, applied.width == canvasWidth,
      applied.height == canvasHeight
    {
      return
    }

    applied = (config, canvasWidth, canvasHeight)
    placed = nil

    guard let config else {
      loaded = nil
      return
    }

    if loaded?.path != config.path {
      loaded = nil
      loaded = (config.path, try FrameCompositor.load(config.path))
    }

    guard let image = loaded?.image else { return }
    placed = try FrameCompositor.place(image, config, canvasHeight: canvasHeight)
    logInfo("Chat overlay \(config.path) at \(Int(config.x)),\(Int(config.y)) scale \(config.scale)")
  }

  /// The canvas frame for a captured frame.
  func apply(_ frame: CVPixelBuffer) -> CVPixelBuffer {
    lock.lock()
    let overlay = placed
    let canvas = self.canvas
    lock.unlock()

    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    let fits = canvas.width == 0 || (width == canvas.width && height == canvas.height)

    if fits && overlay == nil { return frame }

    let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    var image = CIImage(cvPixelBuffer: frame)

    if !fits {
      let rect = FrameCompositor.fit(
        CGSize(width: width, height: height), width: canvas.width, height: canvas.height)

      // Centered, so the bottom-left origin of Core Image needs no flip.
      let transform = CGAffineTransform(
        scaleX: rect.width / CGFloat(width), y: rect.height / CGFloat(height)
      ).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))

      image = image.transformed(by: transform)
        .composited(over: CIImage(color: .black).cropped(to: bounds))
    }

    if let overlay {
      image = overlay.composited(over: image)
    }

    guard let output = makeBuffer(like: frame, width: canvas.width, height: canvas.height)
    else { return frame }

    context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
    CVBufferPropagateAttachments(frame, output)
    return output
  }

  /// The largest rectangle with the content's aspect ratio that fits the
  /// canvas, centered, with even sizes (4:2:0 chroma needs them).
  static func fit(_ content: CGSize, width: Int, height: Int) -> CGRect {
    let canvasWidth = CGFloat(width)
    let canvasHeight = CGFloat(height)

    guard content.width > 0, content.height > 0 else {
      return CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    }

    let scale = min(canvasWidth / content.width, canvasHeight / content.height)
    let fitWidth = min(canvasWidth, 2 * (content.width * scale / 2).rounded())
    let fitHeight = min(canvasHeight, 2 * (content.height * scale / 2).rounded())

    return CGRect(
      x: ((canvasWidth - fitWidth) / 2).rounded(.down),
      y: ((canvasHeight - fitHeight) / 2).rounded(.down),
      width: fitWidth, height: fitHeight)
  }

  /// First frame of any image format ImageIO reads (PNG, JPEG, GIF...).
  static func load(_ path: String) throws -> CIImage {
    let url = URL(fileURLWithPath: path) as CFURL

    guard let source = CGImageSourceCreateWithURL(url, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw HelperError.failed("Cannot read chat overlay image \(path)")
    }

    return CIImage(cgImage: image)
  }

  /// Crop, scale and position the overlay in Core Image coordinates
  /// (bottom-left origin), from top-left canvas coordinates.
  static func place(_ image: CIImage, _ config: OverlayConfig, canvasHeight: Int) throws
    -> CIImage
  {
    let extent = image.extent
    let cropX = CGFloat(config.cropX)
    let cropY = CGFloat(config.cropY)
    let scale = CGFloat(config.scale)

    let crop = CGRect(
      x: extent.minX + cropX, y: extent.minY + cropY,
      width: extent.width - 2 * cropX, height: extent.height - 2 * cropY)

    guard crop.width >= 1, crop.height >= 1, scale > 0 else {
      throw HelperError.invalidArgument("chat overlay crop or scale leaves nothing to draw")
    }

    let left = CGFloat(config.x)
    let bottom = CGFloat(canvasHeight) - CGFloat(config.y) - crop.height * scale
    let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      .concatenating(CGAffineTransform(translationX: left, y: bottom))

    return image.cropped(to: crop).transformed(by: transform)
  }

  private func makeBuffer(like frame: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
    let type = CVPixelBufferGetPixelFormatType(frame)

    if pool == nil || poolFormat?.width != width || poolFormat?.height != height
      || poolFormat?.type != type
    {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: type,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ]

      var created: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
      pool = created
      poolFormat = (width, height, type)
    }

    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return buffer
  }
}
