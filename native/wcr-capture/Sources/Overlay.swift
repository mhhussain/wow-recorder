import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Draws the chat overlay image onto video frames before they are encoded
/// (libobs did this with an image source in the scene). Frames pass through
/// untouched when no overlay is set. Rendering runs on the GPU through Core
/// Image into pooled buffers matching the input frames.
final class OverlayCompositor {
  private let lock = NSLock()
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

  /// Placed overlay, guarded by `lock`.
  private var placed: CIImage?
  private var applied: (config: OverlayConfig?, canvasHeight: Int)?

  /// The decoded image, so moving or scaling it does not reread the file.
  /// Cleared when the overlay is turned off, so turning it back on picks
  /// up an edited file.
  private var loaded: (path: String, image: CIImage)?

  /// Only touched from the frame pacer's queue.
  private var pool: CVPixelBufferPool?
  private var poolFormat: (width: Int, height: Int, type: OSType)?

  /// Load and place the overlay. A no-op if nothing changed. Throws when the
  /// image cannot be read; the overlay is then off until the next change.
  func update(_ config: OverlayConfig?, canvasHeight: Int) throws {
    lock.lock()
    defer { lock.unlock() }

    if let applied, applied.config == config, applied.canvasHeight == canvasHeight {
      return
    }

    applied = (config, canvasHeight)
    placed = nil

    guard let config else {
      loaded = nil
      return
    }

    if loaded?.path != config.path {
      loaded = nil
      loaded = (config.path, try OverlayCompositor.load(config.path))
    }

    guard let image = loaded?.image else { return }
    placed = try OverlayCompositor.place(image, config, canvasHeight: canvasHeight)
    logInfo("Chat overlay \(config.path) at \(Int(config.x)),\(Int(config.y)) scale \(config.scale)")
  }

  /// The frame with the overlay drawn on it, or the frame itself.
  func apply(_ frame: CVPixelBuffer) -> CVPixelBuffer {
    lock.lock()
    let overlay = placed
    lock.unlock()

    guard let overlay else { return frame }

    let background = CIImage(cvPixelBuffer: frame)
    guard let output = makeBuffer(like: frame) else { return frame }

    context.render(
      overlay.composited(over: background), to: output, bounds: background.extent,
      colorSpace: colorSpace)
    CVBufferPropagateAttachments(frame, output)
    return output
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

  /// Crop, scale and position in Core Image coordinates (bottom-left
  /// origin), from top-left canvas coordinates.
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

  private func makeBuffer(like frame: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
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
