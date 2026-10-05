import CoreMedia
import Foundation

/// One 1024-frame mixed block. `tracks[i]` is interleaved stereo for track
/// i + 1, or nil when no source is routed to that track (silence).
struct AudioBlock {
  let pts: CMTime
  let frames: Int
  let tracks: [[Float]?]
}

/// Per-source sample ring addressed by absolute sample index, where index =
/// host seconds * 48000. This aligns sources with different capture clocks
/// and delivery jitter onto one timeline.
final class MixerInput {
  var volume: Float
  var tracks: Int
  let isMic: Bool

  private let capacity = 48000 * 4
  private var left: [Float]
  private var right: [Float]
  private var validStart: Int64 = 0
  private var validEnd: Int64 = 0

  // Noise gate state (mic sources with suppression enabled).
  var gateGain: Float = 1
  var gateHoldUntil: Int64 = 0

  // Volmeter accumulation.
  var peak: Float = 0

  init(volume: Float, tracks: Int, isMic: Bool) {
    self.volume = volume
    self.tracks = tracks
    self.isMic = isMic
    left = [Float](repeating: 0, count: capacity)
    right = [Float](repeating: 0, count: capacity)
  }

  func write(start requested: Int64, left l: [Float], right r: [Float], minIndex: Int64) {
    var start = requested
    let empty = validEnd <= validStart

    // Treat small timestamp jitter as contiguous to avoid clicks.
    if !empty && abs(start - validEnd) < 960 {
      start = validEnd
    }

    var offset = 0

    if start < minIndex {
      // Already mixed past this point; drop the late part.
      offset = Int(minIndex - start)
      start = minIndex
    }

    let count = l.count - offset
    guard count > 0 else { return }

    if empty || start - validEnd >= Int64(capacity) {
      validStart = start
      validEnd = start
    } else if start > validEnd {
      // Gap: zero-fill so stale ring data is never mixed.
      var i = validEnd
      while i < start {
        let slot = Int(i % Int64(capacity))
        left[slot] = 0
        right[slot] = 0
        i += 1
      }
    }

    for i in 0..<count {
      let slot = Int((start + Int64(i)) % Int64(capacity))
      left[slot] = l[offset + i]
      right[slot] = r[offset + i]
    }

    validEnd = max(validEnd, start + Int64(count))
    validStart = max(validStart, validEnd - Int64(capacity))
  }

  func read(start: Int64, count: Int, left outL: inout [Float], right outR: inout [Float]) {
    for i in 0..<count {
      let index = start + Int64(i)
      if index >= validStart && index < validEnd {
        let slot = Int(index % Int64(capacity))
        outL[i] = left[slot]
        outR[i] = right[slot]
      } else {
        outL[i] = 0
        outR[i] = 0
      }
    }
  }
}

/// Mixes all sources into six stereo tracks on a fixed clock, a fixed
/// latency behind real time so late-arriving capture data still lands.
final class AudioMixer {
  static let blockFrames = 1024
  static let trackCount = 6
  static let sampleRate: Int64 = 48000

  let queue = DispatchQueue(label: "wcr.mixer", qos: .userInteractive)
  private let lock = NSLock()
  private var inputs: [String: MixerInput] = [:]
  private var cursor: Int64 = -1
  private var timer: DispatchSourceTimer?
  private var blocksSinceVolmeter = 0

  /// Mixed blocks are only produced while this is true (buffering).
  private var producing = false
  private let latencyFrames: Int64 = 4800

  private var forceMono = false
  private var suppression = false
  private var muteInputs = false
  private var volmeterEnabled = false

  var onBlock: ((AudioBlock) -> Void)?
  var onVolmeter: ((String, Float) -> Void)?

  static func index(for time: CMTime) -> Int64 {
    Int64((CMTimeGetSeconds(time) * Double(sampleRate)).rounded())
  }

  static func index(forSeconds seconds: Double) -> Int64 {
    Int64((seconds * Double(sampleRate)).rounded())
  }

  func setOptions(forceMono: Bool, suppression: Bool, muteInputs: Bool) {
    lock.lock()
    self.forceMono = forceMono
    self.suppression = suppression
    self.muteInputs = muteInputs
    lock.unlock()
  }

  func setVolmeterEnabled(_ enabled: Bool) {
    lock.lock()
    volmeterEnabled = enabled
    lock.unlock()
  }

  func addInput(_ name: String, volume: Float, tracks: Int, isMic: Bool) {
    lock.lock()
    inputs[name] = MixerInput(volume: volume, tracks: tracks, isMic: isMic)
    lock.unlock()
    updateTimer()
  }

  func updateInput(_ name: String, volume: Float, tracks: Int) {
    lock.lock()
    if let input = inputs[name] {
      input.volume = volume
      input.tracks = tracks
    }
    lock.unlock()
  }

  func removeInput(_ name: String) {
    lock.lock()
    inputs.removeValue(forKey: name)
    lock.unlock()
    updateTimer()
  }

  func push(_ name: String, _ chunk: PCMChunk) {
    lock.lock()
    defer { lock.unlock() }
    guard let input = inputs[name] else { return }
    input.write(
      start: AudioMixer.index(for: chunk.pts), left: chunk.left, right: chunk.right,
      minIndex: max(cursor, 0))
  }

  func setProducing(_ value: Bool) {
    lock.lock()
    producing = value
    lock.unlock()
    updateTimer()
  }

  /// Mix everything up to now, ignoring the latency window. Used on stop so
  /// the audio covers the end of the video.
  func flush() {
    queue.sync {
      let now = AudioMixer.index(forSeconds: HostClock.seconds())
      self.mix(upTo: now)
    }
  }

  private func updateTimer() {
    lock.lock()
    let shouldRun = producing || !inputs.isEmpty
    lock.unlock()

    queue.async {
      if shouldRun && self.timer == nil {
        self.lock.lock()
        self.cursor = AudioMixer.index(forSeconds: HostClock.seconds()) - self.latencyFrames
        self.lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
          guard let self else { return }
          let now = AudioMixer.index(forSeconds: HostClock.seconds())
          self.mix(upTo: now - self.latencyFrames)
        }
        timer.resume()
        self.timer = timer
      } else if !shouldRun, let timer = self.timer {
        timer.cancel()
        self.timer = nil
      }
    }
  }

  /// Runs on `queue`.
  private func mix(upTo target: Int64) {
    let n = AudioMixer.blockFrames

    while cursor + Int64(n) <= target {
      lock.lock()
      let block = mixBlock(start: cursor, frames: n)
      let emit = producing
      cursor += Int64(n)
      lock.unlock()

      if emit, let block {
        onBlock?(block)
      }
    }
  }

  /// Called with `lock` held.
  private func mixBlock(start: Int64, frames n: Int) -> AudioBlock? {
    var outL = [[Float]](repeating: [Float](repeating: 0, count: n), count: AudioMixer.trackCount)
    var outR = outL
    var used = [Bool](repeating: false, count: AudioMixer.trackCount)
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)

    for (_, input) in inputs {
      input.read(start: start, count: n, left: &l, right: &r)

      if input.isMic {
        if forceMono {
          for i in 0..<n {
            let m = (l[i] + r[i]) * 0.5
            l[i] = m
            r[i] = m
          }
        }

        if suppression {
          applyGate(input, start: start, left: &l, right: &r)
        }

        if muteInputs {
          for i in 0..<n {
            l[i] = 0
            r[i] = 0
          }
        }
      }

      var peak: Float = 0
      let volume = input.volume

      for i in 0..<n {
        l[i] *= volume
        r[i] *= volume
        peak = max(peak, abs(l[i]), abs(r[i]))
      }

      input.peak = max(input.peak, peak)

      for t in 0..<AudioMixer.trackCount where input.tracks & (1 << t) != 0 {
        used[t] = true
        for i in 0..<n {
          outL[t][i] += l[i]
          outR[t][i] += r[i]
        }
      }
    }

    blocksSinceVolmeter += 1

    if blocksSinceVolmeter >= 3 {
      blocksSinceVolmeter = 0
      if volmeterEnabled, let onVolmeter {
        for (name, input) in inputs {
          onVolmeter(name, min(input.peak, 1))
        }
      }
      for (_, input) in inputs { input.peak = 0 }
    }

    var tracks: [[Float]?] = []

    for t in 0..<AudioMixer.trackCount {
      if !used[t] {
        tracks.append(nil)
        continue
      }

      var interleaved = [Float](repeating: 0, count: n * 2)
      for i in 0..<n {
        interleaved[2 * i] = min(max(outL[t][i], -1), 1)
        interleaved[2 * i + 1] = min(max(outR[t][i], -1), 1)
      }
      tracks.append(interleaved)
    }

    return AudioBlock(
      pts: CMTime(value: start, timescale: CMTimeScale(AudioMixer.sampleRate)),
      frames: n,
      tracks: tracks)
  }

  /// Simple noise gate standing in for OBS's noise suppression filter:
  /// opens above -40 dBFS RMS, closes below -46 dBFS after a 300 ms hold,
  /// with a per-block linear gain ramp.
  private func applyGate(
    _ input: MixerInput, start: Int64, left l: inout [Float], right r: inout [Float]
  ) {
    let n = l.count
    var sum: Float = 0
    for i in 0..<n { sum += l[i] * l[i] + r[i] * r[i] }
    let rms = (sum / Float(2 * n)).squareRoot()

    let open: Float = 0.01
    let close: Float = 0.005
    var target: Float = input.gateGain > 0.5 ? 1 : 0

    if rms >= open {
      target = 1
      input.gateHoldUntil = start + AudioMixer.sampleRate * 3 / 10
    } else if rms < close && start > input.gateHoldUntil {
      target = 0
    }

    let from = input.gateGain
    for i in 0..<n {
      let g = from + (target - from) * Float(i + 1) / Float(n)
      l[i] *= g
      r[i] *= g
    }
    input.gateGain = target
  }
}
