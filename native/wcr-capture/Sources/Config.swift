import CoreMedia
import Foundation

/// What to capture for video.
///   - "display": a whole display, by CGDirectDisplayID (falls back to main).
///   - "wow": the World of Warcraft window, found and re-found automatically.
///   - "none": black frames only.
struct VideoTargetConfig: Codable, Equatable {
  var kind: String
  var displayId: UInt32?
  var showCursor: Bool
}

/// One audio source in the mix.
///   - "system": all system audio except this app (ScreenCaptureKit).
///   - "app": audio of one application by bundle ID, or "wow" for any WoW
///     client (ScreenCaptureKit).
///   - "mic": a microphone by AVCaptureDevice uniqueID, or "default".
struct AudioSourceConfig: Codable, Equatable {
  var name: String
  var kind: String
  var device: String?
  var volume: Float
  var tracks: Int
}

/// Full desired state, sent by the Electron side on every change.
struct EngineConfig: Codable, Equatable {
  var outputDir: String
  var fps: Int
  var width: Int
  var height: Int
  var encoder: String
  var quality: Double
  var video: VideoTargetConfig
  var audio: [AudioSourceConfig]
  var forceMono: Bool
  var suppression: Bool
  var muteInputs: Bool
  var excludeBundlePrefix: String?
  var bufferSeconds: Double

  static let `default` = EngineConfig(
    outputDir: "",
    fps: 60,
    width: 1920,
    height: 1080,
    encoder: Encoders.h264,
    quality: 0.6,
    video: VideoTargetConfig(kind: "none", displayId: nil, showCursor: false),
    audio: [],
    forceMono: false,
    suppression: false,
    muteInputs: false,
    excludeBundlePrefix: nil,
    bufferSeconds: 60)
}

/// Encoder identifiers exposed to the app. They match the libobs
/// mac-videotoolbox encoder IDs so the settings read naturally.
enum Encoders {
  static let h264 = "com.apple.videotoolbox.videoencoder.ave.avc"
  static let hevc = "com.apple.videotoolbox.videoencoder.ave.hevc"

  static func codec(for id: String) -> CMVideoCodecType {
    id == hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
  }
}

enum HostClock {
  static let clock = CMClockGetHostTimeClock()

  static func now() -> CMTime { CMClockGetTime(clock) }

  static func seconds() -> Double { CMTimeGetSeconds(now()) }
}

/// Matches WoW clients (Retail, Classic, PTR) by bundle ID or name.
func isWowApplication(bundleId: String?, name: String?) -> Bool {
  if let bundleId, bundleId.lowercased().hasPrefix("com.blizzard.worldofwarcraft") {
    return true
  }

  if let name, name.hasPrefix("World of Warcraft") {
    return true
  }

  return false
}
