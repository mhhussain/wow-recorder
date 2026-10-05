import CoreMedia
import Foundation

/// In-memory replay buffer of encoded video and mixed PCM audio, equivalent
/// to the libobs replay_buffer (60 s / 1 GB in upstream). Always starts on a
/// keyframe so a recording can be cut from any retained point.
final class MediaBuffer {
  private(set) var video: [VideoSample] = []
  private(set) var audio: [AudioBlock] = []
  private var videoBytes = 0

  var maxSeconds: Double = 60
  var maxBytes = 1 << 30

  func reset() {
    video.removeAll()
    audio.removeAll()
    videoBytes = 0
  }

  func appendVideo(_ sample: VideoSample) {
    video.append(sample)
    videoBytes += sample.byteCount
    trim()
  }

  func appendAudio(_ block: AudioBlock) {
    audio.append(block)

    // Audio is trimmed relative to the oldest video so both cover the same
    // window. Before any video exists, keep it bounded by time alone.
    let horizon: Double
    if let first = video.first {
      horizon = CMTimeGetSeconds(first.pts) - 1
    } else {
      horizon = CMTimeGetSeconds(block.pts) - maxSeconds
    }

    var drop = 0
    while drop < audio.count && CMTimeGetSeconds(audio[drop].pts) < horizon {
      drop += 1
    }
    if drop > 0 { audio.removeFirst(drop) }
  }

  private func trim() {
    guard let newest = video.last else { return }
    let cutoff = CMTimeGetSeconds(newest.pts) - maxSeconds

    // Keep from the latest keyframe at or before the cutoff, so at least
    // maxSeconds remain and the buffer starts on a keyframe.
    var keep = 0
    for (i, sample) in video.enumerated() {
      if CMTimeGetSeconds(sample.pts) > cutoff { break }
      if sample.isKeyframe { keep = i }
    }

    if keep > 0 { dropVideo(keep) }

    // Enforce the size cap by dropping whole GOPs.
    while videoBytes > maxBytes, let next = nextKeyframe(after: 0), next < video.count - 1 {
      dropVideo(next)
    }
  }

  private func dropVideo(_ count: Int) {
    videoBytes -= video[..<count].reduce(0) { $0 + $1.byteCount }
    video.removeFirst(count)
  }

  private func nextKeyframe(after index: Int) -> Int? {
    var i = index + 1
    while i < video.count {
      if video[i].isKeyframe { return i }
      i += 1
    }
    return nil
  }

  /// Everything from the latest keyframe at or before `target`, or from the
  /// oldest keyframe if `target` is older than the buffer.
  func snapshot(from target: CMTime) -> (video: [VideoSample], audio: [AudioBlock])? {
    guard !video.isEmpty else { return nil }
    let targetSeconds = CMTimeGetSeconds(target)

    var start: Int?
    for (i, sample) in video.enumerated() where sample.isKeyframe {
      if CMTimeGetSeconds(sample.pts) <= targetSeconds || start == nil {
        start = i
      } else {
        break
      }
    }

    guard let start else { return nil }
    let keyframePTS = CMTimeGetSeconds(video[start].pts)
    let blockSeconds = Double(AudioMixer.blockFrames) / PCM.sampleRate
    let audioFrom = audio.filter { CMTimeGetSeconds($0.pts) + blockSeconds > keyframePTS }
    return (Array(video[start...]), audioFrom)
  }

  var durationSeconds: Double {
    guard let first = video.first, let last = video.last else { return 0 }
    return CMTimeGetSeconds(last.pts) - CMTimeGetSeconds(first.pts)
  }
}
