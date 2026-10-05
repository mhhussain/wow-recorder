import AudioToolbox
import CoreMedia
import Foundation

/// A chunk of 48 kHz stereo float audio with a host-clock start time.
struct PCMChunk {
  let pts: CMTime
  let left: [Float]
  let right: [Float]
}

enum PCM {
  static let sampleRate: Double = 48000

  /// Interleaved float32 stereo at 48 kHz, the format the mixer hands to the
  /// AAC encoders.
  static let stereoFormat: CMAudioFormatDescription = {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0)

    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo

    var format: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: MemoryLayout<AudioChannelLayout>.size,
      layout: &layout,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &format)

    precondition(status == noErr && format != nil, "Failed to create PCM format: \(status)")
    return format!
  }()

  /// Copy interleaved stereo samples into a CMSampleBuffer for AVAssetWriter.
  static func makeSampleBuffer(interleaved: [Float], frames: Int, pts: CMTime) -> CMSampleBuffer? {
    let byteCount = frames * 8
    var block: CMBlockBuffer?

    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: byteCount,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: byteCount,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block)

    guard status == noErr, let block else { return nil }

    status = interleaved.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: byteCount)
    }

    guard status == noErr else { return nil }

    var sample: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: stereoFormat,
      sampleCount: frames,
      presentationTimeStamp: pts,
      packetDescriptions: nil,
      sampleBufferOut: &sample)

    return status == noErr ? sample : nil
  }

  /// Convert any linear PCM sample buffer (float32 or int16, interleaved or
  /// not, mono or stereo) into a 48 kHz stereo float chunk. Other sample
  /// rates are linearly resampled; that path is a safety net, the capture
  /// sources are configured for 48 kHz.
  static func extract(_ sample: CMSampleBuffer, pts overridePTS: CMTime? = nil) -> PCMChunk? {
    guard let format = CMSampleBufferGetFormatDescription(sample),
      let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return nil }

    let asbd = asbdPointer.pointee
    guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0 else { return nil }

    var sizeNeeded = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: &sizeNeeded,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil)

    guard sizeNeeded > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
    defer { raw.deallocate() }
    let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var retained: CMBlockBuffer?

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample,
      bufferListSizeNeededOut: nil,
      bufferListOut: listPointer,
      bufferListSize: sizeNeeded,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &retained)

    guard status == noErr else { return nil }

    let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isInt16 = !isFloat && asbd.mBitsPerChannel == 16
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let channels = Int(asbd.mChannelsPerFrame)

    guard (isFloat && asbd.mBitsPerChannel == 32) || isInt16, channels > 0 else {
      return nil
    }

    func value(_ buffer: AudioBuffer, _ index: Int) -> Float {
      guard let data = buffer.mData else { return 0 }
      if isFloat {
        return data.assumingMemoryBound(to: Float.self)[index]
      }
      return Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
    }

    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)

    if nonInterleaved {
      let l = buffers[0]
      let r = buffers.count > 1 ? buffers[1] : buffers[0]
      for i in 0..<frames {
        left[i] = value(l, i)
        right[i] = value(r, i)
      }
    } else {
      let b = buffers[0]
      for i in 0..<frames {
        left[i] = value(b, i * channels)
        right[i] = channels > 1 ? value(b, i * channels + 1) : left[i]
      }
    }

    let pts = overridePTS ?? CMSampleBufferGetPresentationTimeStamp(sample)

    if abs(asbd.mSampleRate - sampleRate) > 1 {
      left = resample(left, from: asbd.mSampleRate)
      right = resample(right, from: asbd.mSampleRate)
    }

    return PCMChunk(pts: pts, left: left, right: right)
  }

  private static func resample(_ input: [Float], from rate: Double) -> [Float] {
    guard rate > 0, input.count > 1 else { return input }
    let ratio = rate / sampleRate
    let count = Int(Double(input.count) / ratio)
    var output = [Float](repeating: 0, count: count)

    for i in 0..<count {
      let position = Double(i) * ratio
      let index = Int(position)
      let fraction = Float(position - Double(index))
      let a = input[min(index, input.count - 1)]
      let b = input[min(index + 1, input.count - 1)]
      output[i] = a + (b - a) * fraction
    }

    return output
  }
}
