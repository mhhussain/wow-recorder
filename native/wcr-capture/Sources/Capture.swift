import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol VideoFrameSource: AnyObject {
  func start(config: EngineConfig, onFrame: @escaping (CVPixelBuffer) -> Void) throws
  func stop()
}

protocol AudioCaptureSource: AnyObject {
  func start(onChunk: @escaping (PCMChunk) -> Void) throws
  func stop()
}

protocol CaptureFactory {
  func makeVideoSource() -> VideoFrameSource
  func makeAudioSource(_ source: AudioSourceConfig, config: EngineConfig) -> AudioCaptureSource
}

enum SCK {
  static func content() throws -> SCShareableContent {
    try waitFor("SCShareableContent", timeout: 10) { done in
      SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) {
        content, error in
        done(content, error)
      }
    }
  }

  static func start(_ stream: SCStream) throws {
    let _: Bool = try waitFor("SCStream.startCapture", timeout: 10) { done in
      stream.startCapture { error in done(error == nil, error) }
    }
  }

  static func stop(_ stream: SCStream) {
    do {
      let _: Bool = try waitFor("SCStream.stopCapture", timeout: 5) { done in
        stream.stopCapture { error in done(error == nil, error) }
      }
    } catch {
      logWarn("stopCapture: \(error)")
    }
  }

  static func requireScreenPermission() throws {
    if !CGPreflightScreenCaptureAccess() {
      // Shows the system prompt once per app identity; later calls are no-ops.
      _ = CGRequestScreenCaptureAccess()
      throw HelperError.permission(
        "Screen & System Audio Recording is not allowed for Warcraft Recorder. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Warcraft Recorder."
      )
    }
  }

  /// The largest normal-layer window owned by a WoW client.
  static func findWowWindow(_ content: SCShareableContent) -> SCWindow? {
    content.windows
      .filter {
        $0.windowLayer == 0
          && isWowApplication(
            bundleId: $0.owningApplication?.bundleIdentifier,
            name: $0.owningApplication?.applicationName)
      }
      .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
  }
}

/// ScreenCaptureKit video capture of a display or the WoW window. WoW mode
/// survives the window not existing yet, being recreated (fullscreen
/// toggles) or closing: it keeps re-finding the window while black frames
/// fill the gap.
final class SCKVideoSource: NSObject, VideoFrameSource, SCStreamOutput, SCStreamDelegate {
  private let queue = DispatchQueue(label: "wcr.sck.video", qos: .userInteractive)
  private let control = DispatchQueue(label: "wcr.sck.video.control")
  private var activeStream: SCStream?
  private var config = EngineConfig.default
  private var onFrame: ((CVPixelBuffer) -> Void)?
  private var watchdog: DispatchSourceTimer?
  private var running = false
  private var windowID: CGWindowID?
  private var lastFrame = Date.distantPast

  func start(config: EngineConfig, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
    try SCK.requireScreenPermission()
    self.config = config
    self.onFrame = onFrame

    try control.sync {
      running = true
      try attach()
    }

    if config.video.kind == "wow" {
      let timer = DispatchSource.makeTimerSource(queue: control)
      timer.schedule(deadline: .now() + 3, repeating: 3)
      timer.setEventHandler { [weak self] in self?.checkWindow() }
      timer.resume()
      watchdog = timer
    }
  }

  func stop() {
    watchdog?.cancel()
    watchdog = nil
    control.sync {
      running = false
      detach()
    }
    onFrame = nil
  }

  /// Runs on `control`.
  private func attach() throws {
    guard running, activeStream == nil else { return }
    let content = try SCK.content()
    let filter: SCContentFilter

    switch config.video.kind {
    case "display":
      let wanted = config.video.displayId
      guard
        let display = content.displays.first(where: { $0.displayID == wanted })
          ?? content.displays.first
      else {
        throw HelperError.failed("No displays available to capture")
      }
      filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      logInfo("Capturing display \(display.displayID) (\(display.width)x\(display.height))")

    case "wow":
      guard let window = SCK.findWowWindow(content) else {
        logInfo("WoW window not found yet, will retry")
        return
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      windowID = window.windowID
      logInfo(
        "Capturing WoW window \(window.windowID) '\(window.title ?? "")' \(Int(window.frame.width))x\(Int(window.frame.height))"
      )

    default:
      return
    }

    let sc = SCStreamConfiguration()
    sc.width = config.width
    sc.height = config.height
    sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
    sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    sc.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    sc.colorSpaceName = CGColorSpace.itur_709
    sc.showsCursor = config.video.showCursor
    sc.queueDepth = 8
    sc.scalesToFit = true
    sc.preservesAspectRatio = true
    sc.captureResolution = .best
    sc.backgroundColor = CGColor(gray: 0, alpha: 1)
    sc.capturesAudio = false

    let stream = SCStream(filter: filter, configuration: sc, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try SCK.start(stream)
    activeStream = stream
    lastFrame = Date()
  }

  /// Runs on `control`.
  private func detach() {
    if let current = activeStream {
      SCK.stop(current)
    }
    activeStream = nil
    windowID = nil
  }

  /// Re-find the WoW window if we have none, or if frames stopped arriving
  /// and the window we hold no longer exists.
  private func checkWindow() {
    guard running else { return }

    if activeStream == nil {
      do { try attach() } catch { logWarn("WoW window attach failed: \(error)") }
      return
    }

    // WoW renders continuously, so a long frame gap means the window went
    // away or was replaced.
    guard Date().timeIntervalSince(lastFrame) > 2 else { return }

    do {
      let content = try SCK.content()
      if let current = SCK.findWowWindow(content), current.windowID == windowID {
        return
      }
      logInfo("WoW window changed or closed, re-attaching")
      detach()
      try attach()
    } catch {
      logWarn("WoW window check failed: \(error)")
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw)
    else { return }

    if status == .idle {
      // Nothing changed on screen; still counts as alive.
      lastFrame = Date()
      return
    }

    guard status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    lastFrame = Date()
    onFrame?(pixelBuffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    logWarn("Video stream stopped: \(error.localizedDescription)")
    control.async {
      guard self.activeStream === stream else { return }
      self.activeStream = nil
      self.windowID = nil
      if self.running && self.config.video.kind == "display" {
        do { try self.attach() } catch { logError("Display re-attach failed: \(error)") }
      }
      // WoW mode re-attaches from the watchdog.
    }
  }
}

/// ScreenCaptureKit audio: either all system audio (minus this app) or one
/// application's audio. A tiny, slow video stream is required by the API and
/// discarded.
final class SCKAudioSource: NSObject, AudioCaptureSource, SCStreamOutput, SCStreamDelegate {
  private let queue = DispatchQueue(label: "wcr.sck.audio", qos: .userInteractive)
  private let control = DispatchQueue(label: "wcr.sck.audio.control")
  private let source: AudioSourceConfig
  private let excludeBundlePrefix: String?
  private var activeStream: SCStream?
  private var onChunk: ((PCMChunk) -> Void)?
  private var retry: DispatchSourceTimer?
  private var running = false

  init(source: AudioSourceConfig, excludeBundlePrefix: String?) {
    self.source = source
    self.excludeBundlePrefix = excludeBundlePrefix
  }

  func start(onChunk: @escaping (PCMChunk) -> Void) throws {
    try SCK.requireScreenPermission()
    self.onChunk = onChunk

    try control.sync {
      running = true
      try attach()
    }

    // Application audio waits for the app to launch, and re-attaches if it
    // restarts.
    if source.kind == "app" {
      let timer = DispatchSource.makeTimerSource(queue: control)
      timer.schedule(deadline: .now() + 3, repeating: 3)
      timer.setEventHandler { [weak self] in
        guard let self, self.running, self.activeStream == nil else { return }
        do { try self.attach() } catch { logWarn("App audio attach failed: \(error)") }
      }
      timer.resume()
      retry = timer
    }
  }

  func stop() {
    retry?.cancel()
    retry = nil
    control.sync {
      running = false
      if let current = activeStream { SCK.stop(current) }
      activeStream = nil
    }
    onChunk = nil
  }

  private func matchesTarget(_ app: SCRunningApplication) -> Bool {
    let wanted = source.device ?? "wow"
    if wanted == "wow" {
      return isWowApplication(bundleId: app.bundleIdentifier, name: app.applicationName)
    }
    return app.bundleIdentifier == wanted
  }

  /// Runs on `control`.
  private func attach() throws {
    guard running, activeStream == nil else { return }
    let content = try SCK.content()

    guard let display = content.displays.first else {
      throw HelperError.failed("No display available for audio capture")
    }

    let filter: SCContentFilter

    if source.kind == "app" {
      let apps = content.applications.filter(matchesTarget)
      guard !apps.isEmpty else { return }
      filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
      logInfo("Capturing app audio from \(apps.map(\.applicationName)) for \(source.name)")
    } else {
      var excluded: [SCRunningApplication] = []
      if let prefix = excludeBundlePrefix, !prefix.isEmpty {
        excluded = content.applications.filter { $0.bundleIdentifier.hasPrefix(prefix) }
      }
      filter = SCContentFilter(
        display: display, excludingApplications: excluded, exceptingWindows: [])
      logInfo("Capturing system audio for \(source.name), excluding \(excluded.count) app(s)")
    }

    let sc = SCStreamConfiguration()
    sc.capturesAudio = true
    sc.sampleRate = Int(PCM.sampleRate)
    sc.channelCount = 2
    sc.excludesCurrentProcessAudio = true
    sc.width = 2
    sc.height = 2
    sc.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    sc.queueDepth = 3

    let stream = SCStream(filter: filter, configuration: sc, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try SCK.start(stream)
    activeStream = stream
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, sampleBuffer.isValid, let chunk = PCM.extract(sampleBuffer) else {
      return
    }
    onChunk?(chunk)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    logWarn("Audio stream \(source.name) stopped: \(error.localizedDescription)")
    control.async {
      guard self.activeStream === stream else { return }
      self.activeStream = nil
      if self.running && self.source.kind != "app" {
        do { try self.attach() } catch { logError("System audio re-attach failed: \(error)") }
      }
    }
  }
}

/// Microphone capture through AVFoundation. Supports any number of devices,
/// each with its own session, converted to 48 kHz float stereo on the host
/// clock.
final class MicSource: NSObject, AudioCaptureSource, AVCaptureAudioDataOutputSampleBufferDelegate {
  private let queue = DispatchQueue(label: "wcr.mic", qos: .userInteractive)
  private let source: AudioSourceConfig
  private var session: AVCaptureSession?
  private var onChunk: ((PCMChunk) -> Void)?

  init(source: AudioSourceConfig) {
    self.source = source
  }

  static func requireMicPermission() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted: Bool = try waitFor("microphone permission", timeout: 30) { done in
        AVCaptureDevice.requestAccess(for: .audio) { ok in done(ok, nil) }
      }
      if granted { return }
    default:
      break
    }

    throw HelperError.permission(
      "Microphone access is not allowed for Warcraft Recorder. Enable it in System Settings > Privacy & Security > Microphone."
    )
  }

  func start(onChunk: @escaping (PCMChunk) -> Void) throws {
    try MicSource.requireMicPermission()

    let wanted = source.device ?? "default"
    let device =
      (wanted == "default" ? nil : AVCaptureDevice(uniqueID: wanted))
      ?? AVCaptureDevice.default(for: .audio)

    guard let device else {
      throw HelperError.failed("No microphone available for \(source.name)")
    }

    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw HelperError.failed("Cannot add microphone input \(device.localizedName)")
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: PCM.sampleRate,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: true,
      AVLinearPCMIsBigEndianKey: false,
    ]
    output.setSampleBufferDelegate(self, queue: queue)

    guard session.canAddOutput(output) else {
      throw HelperError.failed("Cannot add microphone output")
    }
    session.addOutput(output)

    self.onChunk = onChunk
    self.session = session
    session.startRunning()
    logInfo("Capturing microphone '\(device.localizedName)' for \(source.name)")
  }

  func stop() {
    session?.stopRunning()
    session = nil
    onChunk = nil
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let session else { return }
    var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    // Map the device clock onto the host clock the mixer uses.
    if let clock = session.synchronizationClock {
      pts = CMSyncConvertTime(pts, from: clock, to: HostClock.clock)
    }

    if let chunk = PCM.extract(sampleBuffer, pts: pts) {
      onChunk?(chunk)
    }
  }
}

/// Real capture sources.
struct SystemCaptureFactory: CaptureFactory {
  func makeVideoSource() -> VideoFrameSource { SCKVideoSource() }

  func makeAudioSource(_ source: AudioSourceConfig, config: EngineConfig) -> AudioCaptureSource {
    if source.kind == "mic" {
      return MicSource(source: source)
    }
    return SCKAudioSource(source: source, excludeBundlePrefix: config.excludeBundlePrefix)
  }
}
