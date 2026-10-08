import CoreGraphics
import CoreMedia
import Foundation

/// The recording engine. Mirrors the libobs replay-buffer model the app was
/// built around:
///   startBuffer  -> capture + encode continuously into a 60 s memory buffer
///   convert(n)   -> start a file from n seconds ago and keep writing
///   stop         -> finalize the file
///   forceStop    -> abandon without finalizing
///
/// Signals use the same names as noobs ("start", "converted", "stop",
/// "deactivate") so the TypeScript Recorder logic is unchanged.
final class Engine {
  enum State: String {
    case idle, buffering, recording
  }

  static let audioTracks = 6

  let control = DispatchQueue(label: "wcr.control")
  /// Audio captures start and stop here, in order, off `control`: starting
  /// one can wait on ScreenCaptureKit, which must never delay startBuffer.
  private let audioQueue = DispatchQueue(label: "wcr.audio.sources")
  private let factory: CaptureFactory
  private var config = EngineConfig.default
  private(set) var state = State.idle

  private let mixer = AudioMixer()
  private let compositor = FrameCompositor()
  private let buffer = MediaBuffer()
  private var encoder: VideoEncoder?
  private var pacer: FramePacer?
  private var videoSource: VideoFrameSource?
  private var audioSources: [String: (config: AudioSourceConfig, source: AudioCaptureSource)] = [:]

  /// Guards the hand-over between the replay buffer and the file writer.
  private let dataLock = NSLock()
  private var writer: FileWriter?
  private var pendingConvertPath: String?
  private var lastRecording = ""

  init(factory: CaptureFactory) {
    self.factory = factory

    mixer.onBlock = { [weak self] block in self?.ingestAudio(block) }
    mixer.onVolmeter = { name, value in
      IO.emit(["event": "signal", "type": "volmeter", "id": name, "code": 0, "value": value])
    }
  }

  // MARK: Signals

  private func signal(_ id: String, code: Int = 0, error: String? = nil, path: String? = nil) {
    var message: [String: Any] = ["event": "signal", "type": "output", "id": id, "code": code]
    if let error { message["error"] = error }
    if let path { message["path"] = path }
    IO.emit(message)
  }

  private func reportError(_ message: String) {
    logError(message)
    IO.emit(["event": "error", "message": message])
  }

  // MARK: Commands (all run on `control`)

  func handle(_ command: [String: Any]) throws -> Any? {
    guard let name = command["cmd"] as? String else {
      throw HelperError.invalidArgument("missing cmd")
    }

    switch name {
    case "configure":
      guard let raw = command["config"] else { throw HelperError.invalidArgument("missing config") }
      let data = try JSONSerialization.data(withJSONObject: raw)
      try configure(JSONDecoder().decode(EngineConfig.self, from: data))
      return nil

    case "startBuffer":
      try startBuffer()
      return nil

    case "convert":
      let offset = (command["offset"] as? NSNumber)?.doubleValue ?? 0
      try convert(offset: offset)
      return nil

    case "stop":
      stop(force: false)
      return nil

    case "forceStop":
      stop(force: true)
      return nil

    case "getLastRecording":
      return lastRecording

    case "setVolmeter":
      mixer.setVolmeterEnabled((command["enabled"] as? Bool) ?? false)
      return nil

    case "listDevices":
      return Devices.list()

    case "permissions":
      return Devices.permissions()

    case "requestScreenAccess":
      // Shows the system prompt (attributed to the parent app) the first
      // time; afterwards it is a no-op and the user must use System Settings.
      if !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
      }
      return Devices.permissions()

    case "status":
      return ["state": state.rawValue, "bufferSeconds": buffer.durationSeconds] as [String: Any]

    default:
      throw HelperError.invalidArgument("unknown cmd \(name)")
    }
  }

  func configure(_ next: EngineConfig) throws {
    let previous = config
    config = next

    mixer.setOptions(
      forceMono: next.forceMono, suppression: next.suppression, muteInputs: next.muteInputs)
    buffer.maxSeconds = next.bufferSeconds

    reconcileAudio(next)

    do {
      try compositor.update(next.overlay, canvasWidth: next.width, canvasHeight: next.height)
    } catch {
      reportError("Chat overlay is off: \(error)")
    }

    if state != .idle && previous.video != next.video {
      logInfo("Video target changed while active, restarting video capture")
      restartVideoSource()
    }
  }

  /// Bring running audio captures in line with the desired list. Unchanged
  /// sources only get their volume and routing updated.
  private func reconcileAudio(_ next: EngineConfig) {
    let wanted = Dictionary(next.audio.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    for (name, current) in audioSources {
      if let desired = wanted[name], desired.kind == current.config.kind,
        desired.device == current.config.device
      {
        continue
      }
      let source = current.source
      audioQueue.async { source.stop() }
      mixer.removeInput(name)
      audioSources.removeValue(forKey: name)
      logInfo("Removed audio source \(name)")
    }

    for source in next.audio {
      if let existing = audioSources[source.name] {
        mixer.updateInput(source.name, volume: source.volume, tracks: source.tracks)
        audioSources[source.name] = (source, existing.source)
        continue
      }

      let capture = factory.makeAudioSource(source, config: next)
      mixer.addInput(
        source.name, volume: source.volume, tracks: source.tracks, isMic: source.kind == "mic")
      audioSources[source.name] = (source, capture)

      audioQueue.async { [weak self] in
        do {
          try capture.start { [weak self] chunk in self?.mixer.push(source.name, chunk) }
          logInfo("Added audio source \(source.name) (\(source.kind) \(source.device ?? "-"))")
        } catch {
          self?.reportError("Audio source \(source.name) failed: \(error)")

          // Forget it so the next configure tries again.
          self?.control.async {
            guard let self, self.audioSources[source.name]?.source === capture else { return }
            self.mixer.removeInput(source.name)
            self.audioSources.removeValue(forKey: source.name)
          }
        }
      }
    }
  }

  private func startBuffer() throws {
    if state != .idle {
      logWarn("startBuffer while \(state.rawValue)")
      signal("start")
      return
    }

    do {
      guard !config.outputDir.isEmpty else {
        throw HelperError.invalidState("output directory not configured")
      }

      // Callbacks capture the encoder and pacer instances directly rather
      // than reading them through self from other queues.
      let encoder = try VideoEncoder(
        width: config.width, height: config.height, fps: config.fps,
        encoderId: config.encoder, quality: config.quality
      ) { [weak self] sample in self?.ingestVideo(sample) }

      self.encoder = encoder
      buffer.reset()
      let compositor = self.compositor
      pacer = try FramePacer(fps: config.fps, width: config.width, height: config.height) {
        pixelBuffer, pts, duration in
        encoder.encode(compositor.apply(pixelBuffer), pts: pts, duration: duration)
      }

      try startVideoSource()
      mixer.setProducing(true)
      pacer?.start()
      state = .buffering
      signal("start")
      logInfo("Buffer started")
    } catch {
      teardownCapture()
      signal("deactivate", code: -1, error: "\(error)")
      throw error
    }
  }

  private func startVideoSource() throws {
    guard let pacer else { throw HelperError.invalidState("no frame pacer") }
    let source = factory.makeVideoSource()
    try source.start(config: config) { [weak pacer] pixelBuffer in
      pacer?.update(pixelBuffer)
    }
    videoSource = source
  }

  private func restartVideoSource() {
    videoSource?.stop()
    videoSource = nil
    pacer?.update(nil)
    do {
      try startVideoSource()
    } catch {
      reportError("Video capture restart failed: \(error)")
    }
  }

  private func convert(offset: Double) throws {
    guard state == .buffering else {
      throw HelperError.invalidState("convert while \(state.rawValue)")
    }

    let target = CMTimeSubtract(HostClock.now(), CMTime(seconds: max(0, offset), preferredTimescale: 1000))
    let path = Engine.makeOutputPath(directory: config.outputDir)

    dataLock.lock()
    defer { dataLock.unlock() }

    guard let snapshot = buffer.snapshot(from: target), !snapshot.video.isEmpty else {
      // No keyframe yet (convert right after startBuffer). Start on the
      // next keyframe instead.
      logInfo("No buffered video yet, file will start at the next keyframe")
      pendingConvertPath = path
      state = .recording
      return
    }

    try openWriter(path: path, video: snapshot.video, audio: snapshot.audio)
    state = .recording
    logInfo(
      "Converted buffer from \(String(format: "%.2f", offset))s ago: \(snapshot.video.count) frames, \(snapshot.audio.count) audio blocks"
    )
  }

  /// Called with `dataLock` held.
  private func openWriter(path: String, video: [VideoSample], audio: [AudioBlock]) throws {
    guard let first = video.first, let format = CMSampleBufferGetFormatDescription(first.buffer)
    else {
      throw HelperError.failed("no keyframe to start from")
    }

    let writer = try FileWriter(
      url: URL(fileURLWithPath: path), videoFormat: format, startPTS: first.pts,
      audioTracks: Engine.audioTracks)

    video.forEach(writer.appendVideo)
    audio.forEach(writer.appendAudio)
    self.writer = writer
    pendingConvertPath = nil
    signal("converted", path: path)
  }

  /// Encoder callback queue.
  private func ingestVideo(_ sample: VideoSample) {
    dataLock.lock()
    defer { dataLock.unlock() }

    buffer.appendVideo(sample)

    if let writer {
      writer.appendVideo(sample)
    } else if let path = pendingConvertPath, sample.isKeyframe {
      let audio = buffer.snapshot(from: sample.pts)?.audio ?? []
      do {
        try openWriter(path: path, video: [sample], audio: audio)
      } catch {
        pendingConvertPath = nil
        reportError("Failed to open recording: \(error)")
      }
    }
  }

  /// Mixer queue.
  private func ingestAudio(_ block: AudioBlock) {
    dataLock.lock()
    defer { dataLock.unlock() }
    buffer.appendAudio(block)
    writer?.appendAudio(block)
  }

  private func stop(force: Bool) {
    guard state != .idle else {
      logInfo("stop while idle")
      signal("deactivate")
      return
    }

    // Stop producing frames, then drain the encoder and mixer so the file
    // covers everything up to now.
    pacer?.stop()
    videoSource?.stop()
    videoSource = nil
    encoder?.flush()
    if !force { mixer.flush() }
    mixer.setProducing(false)

    dataLock.lock()
    let writer = self.writer
    self.writer = nil
    pendingConvertPath = nil
    dataLock.unlock()

    var path = ""

    if let writer {
      if force {
        writer.cancel()
      } else if let error = writer.finish() {
        reportError("Recording finalize failed: \(error)")
        path = writer.url.path
      } else {
        path = writer.url.path
      }
    }

    teardownCapture()
    lastRecording = path
    state = .idle
    logInfo("Stopped (force: \(force)) file: \(path.isEmpty ? "none" : path)")
    signal("stop", path: path)
    signal("deactivate", path: path)
  }

  private func teardownCapture() {
    pacer?.stop()
    pacer = nil
    videoSource?.stop()
    videoSource = nil
    encoder?.invalidate()
    encoder = nil
    mixer.setProducing(false)

    dataLock.lock()
    buffer.reset()
    dataLock.unlock()
  }

  /// Stop everything, keeping any in-progress recording.
  func shutdown() {
    if state != .idle { stop(force: false) }
    let sources = audioSources.values.map { $0.source }
    audioSources.removeAll()
    audioQueue.sync { sources.forEach { $0.stop() } }
  }

  /// Same naming as the libobs replay buffer ("%CCYY-%MM-%DD %hh-%mm-%ss"),
  /// which the app's buffer-folder ownership check expects.
  static func makeOutputPath(directory: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    var name = formatter.string(from: Date())
    var path = (directory as NSString).appendingPathComponent("\(name).mp4")
    var suffix = 1

    while FileManager.default.fileExists(atPath: path) {
      // Two recordings in the same second: step the timestamp forward so
      // the name still matches the expected pattern.
      name = formatter.string(from: Date().addingTimeInterval(Double(suffix)))
      path = (directory as NSString).appendingPathComponent("\(name).mp4")
      suffix += 1
    }

    return path
  }
}

/// Feeds the encoder at a fixed frame rate with the most recent captured
/// frame (repeating it when the screen is static, black before the first
/// frame). Constant frame rate keeps the 1 s keyframe cadence that cutting
/// relies on.
final class FramePacer {
  private let queue = DispatchQueue(label: "wcr.pacer", qos: .userInteractive)
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var latest: CVPixelBuffer?
  private let black: CVPixelBuffer
  private let fps: Int
  private var lastPTS = CMTime.invalid
  private let onTick: (CVPixelBuffer, CMTime, CMTime) -> Void

  init(
    fps: Int, width: Int, height: Int,
    onTick: @escaping (CVPixelBuffer, CMTime, CMTime) -> Void
  ) throws {
    self.fps = max(1, fps)
    self.onTick = onTick
    black = try PixelBuffers.makeBlack(width: width, height: height)
  }

  func update(_ pixelBuffer: CVPixelBuffer?) {
    lock.lock()
    latest = pixelBuffer
    lock.unlock()
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    let nanos = 1_000_000_000 / fps
    timer.schedule(
      deadline: .now(), repeating: .nanoseconds(nanos), leeway: .microseconds(500))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
  }

  private func tick() {
    lock.lock()
    let frame = latest ?? black
    lock.unlock()

    let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
    var pts = HostClock.now()

    if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
      pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
    }

    lastPTS = pts
    onTick(frame, pts, duration)
  }

  func stop() {
    timer?.cancel()
    timer = nil
    queue.sync {}
    update(nil)
  }
}
