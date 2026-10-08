import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// `wcr-capture selftest <dir>`: drives the real Engine (encoder, mixer,
/// replay buffer, writer, command handling) with synthetic video and audio
/// sources, then inspects the files with AVFoundation. Needs no privacy
/// permissions, so it runs on the CI runner.
enum SelfTest {
  final class SyntheticVideoSource: VideoFrameSource {
    private let queue = DispatchQueue(label: "synthetic.video")
    private var timer: DispatchSourceTimer?
    private var buffers: [CVPixelBuffer] = []
    private var frame = 0
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private let size: (width: Int, height: Int)?

    init(size: (width: Int, height: Int)?) { self.size = size }

    func start(config: EngineConfig, onFrame: @escaping (CVPixelBuffer) -> Void) throws {
      for _ in 0..<6 {
        let buffer = try PixelBuffers.make(
          width: size?.width ?? config.width, height: size?.height ?? config.height)
        buffers.append(buffer)
      }
      self.onFrame = onFrame
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / config.fps))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
    }

    private func tick() {
      let buffer = buffers[frame % buffers.count]
      PixelBuffers.fill(buffer, luma: 64, barColumn: frame * 8)
      frame += 1
      onFrame?(buffer)
    }

    func stop() {
      timer?.cancel()
      timer = nil
      queue.sync {}
    }
  }

  final class SyntheticAudioSource: AudioCaptureSource {
    private let queue = DispatchQueue(label: "synthetic.audio")
    private var timer: DispatchSourceTimer?
    private let frequency: Double
    private var phase: Double = 0
    private var onChunk: ((PCMChunk) -> Void)?

    init(frequency: Double) { self.frequency = frequency }

    func start(onChunk: @escaping (PCMChunk) -> Void) throws {
      self.onChunk = onChunk
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(10))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
    }

    private func tick() {
      let frames = 480
      var samples = [Float](repeating: 0, count: frames)
      let step = 2 * Double.pi * frequency / PCM.sampleRate
      for i in 0..<frames {
        samples[i] = Float(0.5 * sin(phase))
        phase += step
      }
      let pts = CMTimeSubtract(HostClock.now(), CMTime(value: Int64(frames), timescale: 48000))
      onChunk?(PCMChunk(pts: pts, left: samples, right: samples))
    }

    func stop() {
      timer?.cancel()
      timer = nil
      queue.sync {}
    }
  }

  final class SyntheticFactory: CaptureFactory {
    /// Size of the synthetic capture; the canvas size when nil.
    var frameSize: (width: Int, height: Int)?

    func makeVideoSource() -> VideoFrameSource { SyntheticVideoSource(size: frameSize) }

    func makeAudioSource(_ source: AudioSourceConfig, config: EngineConfig) -> AudioCaptureSource {
      SyntheticAudioSource(frequency: source.kind == "mic" ? 880 : 440)
    }
  }

  /// Collects signals emitted by the engine.
  final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []

    func add(_ message: [String: Any]) {
      guard message["event"] as? String == "signal", message["type"] as? String == "output"
      else { return }
      lock.lock()
      items.append(message)
      lock.unlock()
    }

    func wait(for id: String, timeout: Double = 20) -> [String: Any]? {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        lock.lock()
        if let index = items.firstIndex(where: { $0["id"] as? String == id }) {
          let item = items.remove(at: index)
          lock.unlock()
          return item
        }
        lock.unlock()
        usleep(20_000)
      }
      return nil
    }
  }

  struct Inspection {
    var videoTracks = 0
    var audioTracks = 0
    var codec = ""
    var width = 0
    var height = 0
    var duration = 0.0
    var trackRMS: [Double] = []

    var dictionary: [String: Any] {
      [
        "videoTracks": videoTracks, "audioTracks": audioTracks, "codec": codec,
        "width": width, "height": height,
        "duration": (duration * 100).rounded() / 100,
        "trackRMS": trackRMS.map { ($0 * 1000).rounded() / 1000 },
      ]
    }
  }

  static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
  }

  static func inspect(_ path: String) throws -> Inspection {
    let box = ResultBox<Inspection>()
    let sem = DispatchSemaphore(value: 0)

    Task {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        var result = Inspection()
        result.duration = CMTimeGetSeconds(try await asset.load(.duration))

        for track in try await asset.loadTracks(withMediaType: .video) {
          result.videoTracks += 1
          let formats = try await track.load(.formatDescriptions)
          if let format = formats.first {
            result.codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
          }
          let size = try await track.load(.naturalSize)
          result.width = Int(size.width)
          result.height = Int(size.height)
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        result.audioTracks = audioTracks.count

        for track in audioTracks {
          let reader = try AVAssetReader(asset: asset)
          let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
              AVFormatIDKey: kAudioFormatLinearPCM,
              AVLinearPCMBitDepthKey: 32,
              AVLinearPCMIsFloatKey: true,
              AVLinearPCMIsNonInterleaved: false,
              AVLinearPCMIsBigEndianKey: false,
            ])
          reader.add(output)
          reader.startReading()

          var sum = 0.0
          var count = 0
          while let sample = output.copyNextSampleBuffer() {
            if let chunk = PCM.extract(sample) {
              for v in chunk.left { sum += Double(v * v) }
              count += chunk.left.count
            }
          }
          result.trackRMS.append(count > 0 ? (sum / Double(count)).squareRoot() : 0)
        }

        box.set(result, nil)
      } catch {
        box.set(nil, error)
      }
      sem.signal()
    }

    sem.wait()
    return try box.get("inspect")
  }

  /// Write a solid-color PNG (for the overlay check).
  static func writePNG(path: String, width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat)
    throws
  {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw HelperError.failed("CGContext failed") }

    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { throw HelperError.failed("PNG encode failed") }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw HelperError.failed("PNG write failed")
    }
  }

  /// RGB of the given top-left-origin pixels in one decoded frame of the
  /// file's video track.
  static func samplePixels(_ path: String, at points: [(x: Int, y: Int)]) throws -> [[Int]] {
    let box = ResultBox<[[Int]]>()
    let sem = DispatchSemaphore(value: 0)

    Task {
      do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
          throw HelperError.failed("no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()

        // Keep one frame about half a second in; holding every decoded
        // frame could starve the reader.
        var chosen: CMSampleBuffer?
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
          if index <= 15 { chosen = sample }
          index += 1
        }

        guard let chosen, let pixels = CMSampleBufferGetImageBuffer(chosen) else {
          throw HelperError.failed("no decoded frames")
        }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
          throw HelperError.failed("no pixel data")
        }

        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let result = points.map { point -> [Int] in
          let offset = point.y * stride + point.x * 4
          // BGRA
          return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
        }

        box.set(result, nil)
      } catch {
        box.set(nil, error)
      }
      sem.signal()
    }

    sem.wait()
    return try box.get("samplePixels")
  }

  static func configJSON(
    directory: String, encoder: String, width: Int, height: Int, fps: Int,
    overlay: String? = nil
  ) -> String {
    let overlayField = overlay.map { "\"overlay\": \($0)," } ?? ""

    return """
    {"outputDir": "\(directory)", "fps": \(fps), "width": \(width), "height": \(height),
     "encoder": "\(encoder)", "quality": 0.6,
     "video": {"kind": "wow", "showCursor": false},
     "audio": [
       {"name": "WCR Audio Source 1", "kind": "system", "device": "default", "volume": 1, "tracks": 1},
       {"name": "WCR Audio Source 2", "kind": "mic", "device": "default", "volume": 0.5, "tracks": 3}
     ],
     \(overlayField)
     "forceMono": true, "suppression": false, "muteInputs": false,
     "excludeBundlePrefix": "org.WarcraftRecorder", "bufferSeconds": 60}
    """
  }

  static func run(directory: String) -> Int32 {
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)

    let signals = Signals()
    IO.observer = { signals.add($0) }
    let factory = SyntheticFactory()
    let engine = Engine(factory: factory)
    var failures: [String] = []
    var results: [[String: Any]] = []

    func send(_ json: String) -> Any? {
      do {
        let data = Data(json.utf8)
        let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try engine.control.sync { try engine.handle(command) }
      } catch {
        failures.append("command \(json.prefix(40)) failed: \(error)")
        return nil
      }
    }

    func check(_ name: String, _ condition: Bool, _ detail: String) {
      if !condition { failures.append("\(name): \(detail)") }
    }

    func record(
      name: String, encoder: String, width: Int, height: Int, fps: Int,
      bufferFor: Double, offset: Double, recordFor: Double,
      expectCodec: String, expectDuration: ClosedRange<Double>
    ) {
      let config = configJSON(
        directory: directory, encoder: encoder, width: width, height: height, fps: fps)
      _ = send(#"{"id": 1, "cmd": "configure", "config": "# + config + "}")
      _ = send(#"{"id": 2, "cmd": "startBuffer"}"#)
      check(name, signals.wait(for: "start") != nil, "no start signal")

      Thread.sleep(forTimeInterval: bufferFor)
      _ = send(#"{"id": 3, "cmd": "convert", "offset": \#(offset)}"#)
      let converted = signals.wait(for: "converted", timeout: 5)
      check(name, converted != nil, "no converted signal")

      Thread.sleep(forTimeInterval: recordFor)
      _ = send(#"{"id": 4, "cmd": "stop"}"#)
      let deactivate = signals.wait(for: "deactivate")
      let path = deactivate?["path"] as? String ?? ""
      check(name, !path.isEmpty, "no file path on deactivate")
      check(name, path == converted?["path"] as? String, "converted/deactivate path mismatch")

      let last = send(#"{"id": 5, "cmd": "getLastRecording"}"#) as? String
      check(name, last == path, "getLastRecording mismatch")

      guard !path.isEmpty else { return }

      do {
        let info = try inspect(path)
        results.append(["name": name, "path": path, "file": info.dictionary])
        check(name, info.videoTracks == 1, "video tracks \(info.videoTracks)")
        check(name, info.audioTracks == Engine.audioTracks, "audio tracks \(info.audioTracks)")
        check(name, info.codec == expectCodec, "codec \(info.codec)")
        check(name, info.width == width && info.height == height, "size \(info.width)x\(info.height)")
        check(name, expectDuration.contains(info.duration), "duration \(info.duration)")
        if info.trackRMS.count == Engine.audioTracks {
          // Track 1: system (440 Hz) + mic. Track 2: mic only at half
          // volume. Tracks 3-6: no sources, silent.
          check(name, info.trackRMS[0] > 0.1, "track 1 rms \(info.trackRMS[0])")
          check(name, info.trackRMS[1] > 0.05, "track 2 rms \(info.trackRMS[1])")
          check(name, info.trackRMS[2] < 0.001, "track 3 rms \(info.trackRMS[2])")
        }
      } catch {
        failures.append("\(name): inspect failed: \(error)")
      }
    }

    // Normal flow: 4 s of buffer, start 2 s back, record 3 s => ~5 s.
    record(
      name: "h264-offset", encoder: Encoders.h264, width: 1280, height: 720, fps: 60,
      bufferFor: 4, offset: 2, recordFor: 3, expectCodec: "avc1",
      expectDuration: 4.0...6.6)

    // Offset older than the buffer starts at the oldest keyframe.
    record(
      name: "hevc-overlong-offset", encoder: Encoders.hevc, width: 1920, height: 1080, fps: 30,
      bufferFor: 3, offset: 100, recordFor: 2, expectCodec: "hvc1",
      expectDuration: 4.0...6.0)

    // Convert before any frame exists: the file starts at the next keyframe.
    record(
      name: "immediate-convert", encoder: Encoders.h264, width: 1280, height: 720, fps: 60,
      bufferFor: 0, offset: 0, recordFor: 2, expectCodec: "avc1",
      expectDuration: 1.2...2.6)

    // Buffer then stop without converting: no file.
    _ = send(#"{"id": 6, "cmd": "startBuffer"}"#)
    check("buffer-only", signals.wait(for: "start") != nil, "no start signal")
    Thread.sleep(forTimeInterval: 1)
    _ = send(#"{"id": 7, "cmd": "stop"}"#)
    let bufferOnly = signals.wait(for: "deactivate")
    check("buffer-only", (bufferOnly?["path"] as? String) == "", "expected empty path")

    // Force stop while recording: deactivate with no file reported.
    _ = send(#"{"id": 8, "cmd": "startBuffer"}"#)
    _ = signals.wait(for: "start")
    Thread.sleep(forTimeInterval: 1)
    _ = send(#"{"id": 9, "cmd": "convert", "offset": 0.5}"#)
    _ = signals.wait(for: "converted", timeout: 5)
    Thread.sleep(forTimeInterval: 1)
    _ = send(#"{"id": 10, "cmd": "forceStop"}"#)
    let forced = signals.wait(for: "deactivate")
    check("force-stop", (forced?["path"] as? String) == "", "expected empty path")

    // Chat overlay: a solid red 200x100 PNG with its top-left corner at
    // (100, 50) on a 640x360 canvas of gray frames (and a moving white bar).
    do {
      let png = (directory as NSString).appendingPathComponent("overlay-test.png")
      try writePNG(path: png, width: 200, height: 100, red: 1, green: 0, blue: 0)
      let overlay =
        #"{"path": "\#(png)", "x": 100, "y": 50, "scale": 1, "cropX": 0, "cropY": 0}"#
      let config = configJSON(
        directory: directory, encoder: Encoders.h264, width: 640, height: 360, fps: 30,
        overlay: overlay)

      _ = send(#"{"id": 11, "cmd": "configure", "config": "# + config + "}")
      _ = send(#"{"id": 12, "cmd": "startBuffer"}"#)
      check("overlay", signals.wait(for: "start") != nil, "no start signal")
      Thread.sleep(forTimeInterval: 1.5)
      _ = send(#"{"id": 13, "cmd": "convert", "offset": 1}"#)
      _ = signals.wait(for: "converted", timeout: 5)
      Thread.sleep(forTimeInterval: 1.5)
      _ = send(#"{"id": 14, "cmd": "stop"}"#)
      let path = signals.wait(for: "deactivate")?["path"] as? String ?? ""
      check("overlay", !path.isEmpty, "no file")

      if !path.isEmpty {
        // Inside the overlay; below it (would be red if y were flipped);
        // left of it.
        let rgb = try samplePixels(path, at: [(150, 100), (150, 250), (50, 100)])
        results.append(["name": "overlay", "path": path, "rgb": rgb])
        let isRed = { (p: [Int]) in p[0] > 180 && p[1] < 90 && p[2] < 90 }
        check("overlay", isRed(rgb[0]), "inside not red: \(rgb[0])")
        check("overlay", !isRed(rgb[1]), "below is red: \(rgb[1])")
        check("overlay", !isRed(rgb[2]), "left is red: \(rgb[2])")
      }
    } catch {
      failures.append("overlay: \(error)")
    }

    // Letterboxing: a 21:9 capture on a 16:9 canvas is centered with even
    // black bars (ScreenCaptureKit's own scaling pinned it to the top).
    let fit = FrameCompositor.fit(CGSize(width: 3440, height: 1440), width: 1920, height: 1080)
    check("fit", fit == CGRect(x: 0, y: 138, width: 1920, height: 804), "fit \(fit)")

    do {
      factory.frameSize = (640, 274)
      defer { factory.frameSize = nil }

      let config = configJSON(
        directory: directory, encoder: Encoders.h264, width: 640, height: 360, fps: 30)

      _ = send(#"{"id": 15, "cmd": "configure", "config": "# + config + "}")
      _ = send(#"{"id": 16, "cmd": "startBuffer"}"#)
      check("letterbox", signals.wait(for: "start") != nil, "no start signal")
      Thread.sleep(forTimeInterval: 1.5)
      _ = send(#"{"id": 17, "cmd": "convert", "offset": 1}"#)
      _ = signals.wait(for: "converted", timeout: 5)
      Thread.sleep(forTimeInterval: 1.5)
      _ = send(#"{"id": 18, "cmd": "stop"}"#)
      let path = signals.wait(for: "deactivate")?["path"] as? String ?? ""
      check("letterbox", !path.isEmpty, "no file")

      if !path.isEmpty {
        // Picture rows 43...316 of 360: above, below, and inside it.
        let rgb = try samplePixels(path, at: [(320, 20), (320, 340), (100, 180)])
        results.append(["name": "letterbox", "path": path, "rgb": rgb])
        let isBlack = { (p: [Int]) in p.allSatisfy { $0 < 30 } }
        check("letterbox", isBlack(rgb[0]), "top not black: \(rgb[0])")
        check("letterbox", isBlack(rgb[1]), "bottom not black: \(rgb[1])")
        check("letterbox", !isBlack(rgb[2]), "picture is black: \(rgb[2])")
      }
    } catch {
      failures.append("letterbox: \(error)")
    }

    engine.control.sync { engine.shutdown() }
    IO.observer = nil

    IO.emit(["selftest": failures.isEmpty ? "pass" : "fail", "failures": failures, "results": results])
    return failures.isEmpty ? 0 : 1
  }
}
