import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Device enumeration that needs no privacy permission, so the settings UI
/// can populate lists before Screen Recording is granted.
enum Devices {
  static func list() -> [String: Any] {
    var displayIds = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(16, &displayIds, &displayCount)

    let displays: [[String: Any]] = displayIds.prefix(Int(displayCount)).map { id -> [String: Any] in
      [
        "id": Int(id),
        "width": CGDisplayPixelsWide(id),
        "height": CGDisplayPixelsHigh(id),
        "main": CGDisplayIsMain(id) != 0,
      ]
    }

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)

    let mics: [[String: Any]] = discovery.devices.map { device -> [String: Any] in
      ["id": device.uniqueID, "name": device.localizedName]
    }

    let apps: [[String: Any]] = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app -> [String: Any]? in
        guard let bundleId = app.bundleIdentifier else { return nil }
        return [
          "bundleId": bundleId,
          "name": app.localizedName ?? bundleId,
          "pid": Int(app.processIdentifier),
          "wow": isWowApplication(bundleId: bundleId, name: app.localizedName),
        ]
      }

    return [
      "displays": displays,
      "mics": mics,
      "defaultMic": AVCaptureDevice.default(for: .audio)?.uniqueID ?? "",
      "apps": apps,
    ]
  }

  static func permissions() -> [String: Any] {
    let mic: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: mic = "granted"
    case .denied: mic = "denied"
    case .restricted: mic = "restricted"
    case .notDetermined: mic = "not-determined"
    @unknown default: mic = "unknown"
    }

    return ["screen": CGPreflightScreenCaptureAccess(), "microphone": mic]
  }
}
