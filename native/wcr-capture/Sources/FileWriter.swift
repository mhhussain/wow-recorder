import AVFoundation
import CoreMedia
import Foundation

/// Simple FIFO with amortized O(1) pops.
struct FIFO<T> {
  private var items: [T] = []
  private var head = 0

  var isEmpty: Bool { head >= items.count }
  var first: T? { isEmpty ? nil : items[head] }

  mutating func push(_ item: T) { items.append(item) }

  mutating func pop() {
    head += 1
    if head > 1024 && head * 2 > items.count {
      items.removeFirst(head)
      head = 0
    }
  }

  mutating func removeAll() {
    items.removeAll()
    head = 0
  }
}

/// Writes one recording: H.264/HEVC passthrough video plus six AAC tracks
/// encoded from the mixer's PCM, as fragmented MP4 so a crash leaves a
/// recoverable file (same goal as upstream's fragmented MP4 output).
final class FileWriter {
  let url: URL
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInputs: [AVAssetWriterInput]
  private let queue = DispatchQueue(label: "wcr.writer")
  private var pendingVideo = FIFO<CMSampleBuffer>()
  private var pendingAudio = FIFO<AudioBlock>()
  private var timer: DispatchSourceTimer?
  private var reportedFailure = false
  private var lastVideoEnd: CMTime = .invalid
  private let silence = [Float](repeating: 0, count: AudioMixer.blockFrames * 2)

  init(url: URL, videoFormat: CMFormatDescription, startPTS: CMTime, audioTracks: Int) throws {
    self.url = url
    try? FileManager.default.removeItem(at: url)

    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1000)
    writer.shouldOptimizeForNetworkUse = false

    videoInput = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    videoInput.expectsMediaDataInRealTime = true
    videoInput.mediaTimeScale = 90000

    guard writer.canAdd(videoInput) else {
      throw HelperError.failed("Cannot add video input")
    }
    writer.add(videoInput)

    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

    let aac: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: PCM.sampleRate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
      AVChannelLayoutKey: layoutData,
    ]

    var inputs: [AVAssetWriterInput] = []

    for _ in 0..<audioTracks {
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: aac, sourceFormatHint: PCM.stereoFormat)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else {
        throw HelperError.failed("Cannot add audio input")
      }
      writer.add(input)
      inputs.append(input)
    }

    audioInputs = inputs

    guard writer.startWriting() else {
      throw HelperError.failed(
        "startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    writer.startSession(atSourceTime: startPTS)

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.drain() }
    timer.resume()
    self.timer = timer
  }

  func appendVideo(_ sample: VideoSample) {
    queue.async {
      self.pendingVideo.push(sample.buffer)
      self.drain()
    }
  }

  func appendAudio(_ block: AudioBlock) {
    queue.async {
      self.pendingAudio.push(block)
      self.drain()
    }
  }

  /// Runs on `queue`.
  private func drain() {
    guard writer.status == .writing else {
      if writer.status == .failed && !reportedFailure {
        reportedFailure = true
        logError("Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
      }
      pendingVideo.removeAll()
      pendingAudio.removeAll()
      return
    }

    while let sample = pendingVideo.first, videoInput.isReadyForMoreMediaData {
      if !videoInput.append(sample) { break }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      let duration = CMSampleBufferGetDuration(sample)
      lastVideoEnd = duration.isValid ? pts + duration : pts
      pendingVideo.pop()
    }

    while let block = pendingAudio.first,
      audioInputs.allSatisfy({ $0.isReadyForMoreMediaData })
    {
      for (i, input) in audioInputs.enumerated() {
        let data = block.tracks.indices.contains(i) ? (block.tracks[i] ?? silence) : silence
        if let sample = PCM.makeSampleBuffer(interleaved: data, frames: block.frames, pts: block.pts)
        {
          input.append(sample)
        }
      }
      pendingAudio.pop()
    }
  }

  /// Flush everything queued, finalize the file and wait for completion.
  func finish(timeout: Double = 30) -> Error? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      var done = false
      queue.sync {
        self.drain()
        done = (self.pendingVideo.isEmpty && self.pendingAudio.isEmpty) || writer.status != .writing
      }
      if done { break }
      usleep(5000)
    }

    queue.sync {
      self.timer?.cancel()
      self.timer = nil

      if writer.status == .writing {
        videoInput.markAsFinished()
        audioInputs.forEach { $0.markAsFinished() }
        if lastVideoEnd.isValid {
          writer.endSession(atSourceTime: lastVideoEnd)
        }
      }
    }

    guard writer.status == .writing else {
      return writer.error ?? HelperError.failed("Writer not writing at finish")
    }

    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }

    if sem.wait(timeout: .now() + timeout) == .timedOut {
      return HelperError.timeout("finishWriting")
    }

    return writer.status == .completed
      ? nil : (writer.error ?? HelperError.failed("Writer status \(writer.status.rawValue)"))
  }

  func cancel() {
    queue.sync {
      self.timer?.cancel()
      self.timer = nil
      self.pendingVideo.removeAll()
      self.pendingAudio.removeAll()
      if writer.status == .writing {
        writer.cancelWriting()
      }
    }
  }
}
