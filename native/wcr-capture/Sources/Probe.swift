import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// `wcr-capture probe`: report what this machine and SDK support, without
/// needing any privacy permission. Used by CI on the self-hosted runner to
/// verify the backend's assumptions.
enum Probe {
  static func run() -> Int32 {
    var report: [String: Any] = [:]
    let os = ProcessInfo.processInfo.operatingSystemVersion
    report["os"] = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

    // Hardware encoders.
    var listRef: CFArray?
    VTCopyVideoEncoderList(nil, &listRef)
    let encoders = (listRef as? [NSDictionary] ?? []).map { entry -> [String: Any] in
      [
        "id": entry[kVTVideoEncoderList_EncoderID] as? String ?? "",
        "name": entry[kVTVideoEncoderList_DisplayName] as? String ?? "",
        "hardware": entry[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool ?? false,
      ]
    }
    report["encoders"] = encoders.filter { ($0["hardware"] as? Bool) == true }

    // Can each exposed encoder be created with constant quality?
    var sessions: [String: Any] = [:]
    for id in [Encoders.h264, Encoders.hevc] {
      do {
        let encoder = try VideoEncoder(
          width: 1920, height: 1080, fps: 60, encoderId: id, quality: 0.6
        ) { _ in }
        sessions[id] = encoder.rateControl
        encoder.invalidate()
      } catch {
        sessions[id] = "error: \(error)"
      }
    }
    report["encoderSessions"] = sessions

    // ScreenCaptureKit configuration surface used by the helper. Compiling
    // this file proves the SDK has these properties; setting them proves the
    // runtime accepts them.
    let sc = SCStreamConfiguration()
    sc.capturesAudio = true
    sc.excludesCurrentProcessAudio = true
    sc.sampleRate = 48000
    sc.channelCount = 2
    sc.captureMicrophone = true
    sc.preservesAspectRatio = true
    sc.scalesToFit = true
    sc.captureResolution = .best
    report["sck"] =
      [
        "capturesAudio": sc.capturesAudio,
        "captureMicrophone": sc.captureMicrophone,
        "excludesCurrentProcessAudio": sc.excludesCurrentProcessAudio,
        "sampleRate": sc.sampleRate,
        "channelCount": sc.channelCount,
      ] as [String: Any]

    report["permissions"] = Devices.permissions()

    // Without Screen Recording permission (the CI runner service) this is
    // expected to fail; the error text is still informative.
    do {
      let content = try SCK.content()
      report["shareableContent"] = [
        "displays": content.displays.count,
        "windows": content.windows.count,
        "applications": content.applications.count,
      ]
    } catch {
      report["shareableContent"] = "error: \(error)"
    }

    let devices = Devices.list()
    report["mics"] = devices["mics"]
    report["displays"] = devices["displays"]

    IO.emit(report)
    return 0
  }
}
