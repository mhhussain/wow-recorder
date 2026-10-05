import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// An encoded video frame as kept in the replay buffer.
struct VideoSample {
  let buffer: CMSampleBuffer
  let pts: CMTime
  let isKeyframe: Bool
  let byteCount: Int
}

/// Hardware H.264/HEVC encoder. One keyframe per `keyframeInterval` seconds
/// and no B-frames, so the app can cut on whole seconds with stream copy and
/// the replay buffer can start a file on any keyframe.
final class VideoEncoder {
  private var session: VTCompressionSession?
  private let onEncoded: (VideoSample) -> Void
  let rateControl: String

  init(
    width: Int, height: Int, fps: Int, encoderId: String, quality: Double,
    keyframeInterval: Double = 1, onEncoded: @escaping (VideoSample) -> Void
  ) throws {
    self.onEncoded = onEncoded
    let codec = Encoders.codec(for: encoderId)

    var created: VTCompressionSession?
    var status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: codec,
      encoderSpecification: [
        kVTVideoEncoderSpecification_EncoderID: encoderId,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
      ] as CFDictionary,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: nil,
      refcon: nil,
      compressionSessionOut: &created)

    if status != noErr || created == nil {
      logWarn("Encoder \(encoderId) unavailable (\(status)), letting VideoToolbox choose")
      status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(width),
        height: Int32(height),
        codecType: codec,
        encoderSpecification: [
          kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ] as CFDictionary,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &created)
    }

    guard status == noErr, let session = created else {
      throw HelperError.failed("VTCompressionSessionCreate failed: \(status)")
    }

    self.session = session

    func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
      VTSessionSetProperty(session, key: key, value: value)
    }

    _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
    _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keyframeInterval))
    _ = set(
      kVTCompressionPropertyKey_MaxKeyFrameInterval,
      NSNumber(value: max(1, Int(Double(fps) * keyframeInterval))))
    _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
    _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
    _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

    let profile =
      codec == kCMVideoCodecType_HEVC
      ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
    _ = set(kVTCompressionPropertyKey_ProfileLevel, profile)

    // Prefer constant quality (the closest match to OBS CQP/CRF). Fall back
    // to an average bitrate derived from the same quality value if the
    // encoder rejects it.
    let clamped = min(max(quality, 0.05), 1.0)

    if set(kVTCompressionPropertyKey_Quality, NSNumber(value: clamped)) == noErr {
      rateControl = "quality \(clamped)"
    } else {
      let bitsPerPixel = 0.05 + 0.25 * clamped
      let bitrate = Int(Double(width * height * fps) * bitsPerPixel)
      _ = set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
      rateControl = "bitrate \(bitrate)"
    }

    VTCompressionSessionPrepareToEncodeFrames(session)
    logInfo("Video encoder ready: \(encoderId) \(width)x\(height)@\(fps) \(rateControl)")
  }

  func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
    guard let session else { return }

    let status = VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: pts,
      duration: duration,
      frameProperties: nil,
      infoFlagsOut: nil
    ) { [onEncoded] status, _, sample in
      guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else {
        if status != noErr { logWarn("Encode callback error \(status)") }
        return
      }

      var isKeyframe = true

      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[CFString: Any]], let first = attachments.first,
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
      {
        isKeyframe = !notSync
      }

      onEncoded(
        VideoSample(
          buffer: sample,
          pts: CMSampleBufferGetPresentationTimeStamp(sample),
          isKeyframe: isKeyframe,
          byteCount: CMSampleBufferGetTotalSampleSize(sample)))
    }

    if status != noErr {
      logWarn("VTCompressionSessionEncodeFrame failed: \(status)")
    }
  }

  /// Block until every submitted frame has been emitted.
  func flush() {
    guard let session else { return }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
  }

  func invalidate() {
    guard let session else { return }
    flush()
    VTCompressionSessionInvalidate(session)
    self.session = nil
  }

  deinit { invalidate() }
}

enum PixelBuffers {
  /// NV12 (video range) IOSurface-backed buffer filled with black.
  static func makeBlack(width: Int, height: Int) throws -> CVPixelBuffer {
    let buffer = try make(width: width, height: height)
    fill(buffer, luma: 16)
    return buffer
  }

  static func make(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]

    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      attributes as CFDictionary, &buffer)

    guard status == kCVReturnSuccess, let buffer else {
      throw HelperError.failed("CVPixelBufferCreate failed: \(status)")
    }

    CVBufferSetAttachment(
      buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
      .shouldPropagate)
    CVBufferSetAttachment(
      buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
      .shouldPropagate)

    return buffer
  }

  /// Fill the luma plane with a constant (optionally a moving bar) and the
  /// chroma plane with neutral grey.
  static func fill(_ buffer: CVPixelBuffer, luma: UInt8, barColumn: Int? = nil) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)

    if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      for row in 0..<height {
        let line = y.advanced(by: row * stride)
        memset(line, Int32(luma), width)
        if let barColumn {
          let start = barColumn % max(1, width - 32)
          memset(line.advanced(by: start), 235, 32)
        }
      }
    }

    if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      memset(uv, 128, stride * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }
  }
}
