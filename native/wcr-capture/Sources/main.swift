import AppKit
import Foundation

// wcr-capture: macOS recording backend for Warcraft Recorder.
//
//   wcr-capture serve      JSON-lines protocol on stdin/stdout (default)
//   wcr-capture list       print devices once (no permissions needed)
//   wcr-capture probe      print SDK/hardware capabilities (CI)
//   wcr-capture selftest   record synthetic sources and verify the files (CI)
//
// Protocol (serve): one JSON object per line.
//   in:  {"id": 1, "cmd": "configure", "config": {...}}
//   out: {"id": 1, "ok": true, "result": ...} or {"id": 1, "ok": false, "error": "..."}
//   out: {"event": "signal", "type": "output", "id": "start", "code": 0, ...}
//   out: {"event": "signal", "type": "volmeter", "id": "<source>", "value": 0.5}
//   out: {"event": "error", "message": "..."}

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "serve"

func serve() -> Never {
  let engine = Engine(factory: SystemCaptureFactory())
  IO.emit(["event": "ready", "pid": Int(getpid())])

  Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }

      guard let data = line.data(using: .utf8),
        let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else {
        logError("Bad command line: \(line)")
        continue
      }

      let id = command["id"] ?? NSNull()

      engine.control.async {
        do {
          let result = try engine.handle(command)
          IO.emit(["id": id, "ok": true, "result": result ?? NSNull()])
        } catch {
          logError("Command \(command["cmd"] ?? "?") failed: \(error)")
          IO.emit(["id": id, "ok": false, "error": "\(error)"])
        }
      }
    }

    // stdin closed: the app quit or crashed. Finish any recording and exit.
    logInfo("stdin closed, shutting down")
    engine.control.sync { engine.shutdown() }
    exit(0)
  }

  // A running main run loop keeps NSWorkspace and capture callbacks alive.
  RunLoop.main.run()
  exit(0)
}

switch mode {
case "serve":
  serve()
case "list":
  IO.emit(Devices.list())
  exit(0)
case "probe":
  exit(Probe.run())
case "selftest":
  let directory = arguments.count > 2 ? arguments[2] : NSTemporaryDirectory()
  exit(SelfTest.run(directory: directory))
default:
  logError("Unknown mode \(mode)")
  exit(2)
}
