import Foundation

/// Line-oriented JSON on stdout (protocol messages) and plain text on stderr
/// (diagnostics, captured by the Electron main process into its log).
enum IO {
  private static let lock = NSLock()

  /// Test hook: sees every emitted message (selftest only).
  nonisolated(unsafe) static var observer: (([String: Any]) -> Void)?

  static func emit(_ object: [String: Any]) {
    observer?(object)

    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.withoutEscapingSlashes])
    else {
      log("error", "Dropping unserializable message: \(object)")
      return
    }

    lock.lock()
    defer { lock.unlock() }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func log(_ level: String, _ message: String) {
    let line = "[\(level)] \(message)\n"
    lock.lock()
    defer { lock.unlock() }
    FileHandle.standardError.write(Data(line.utf8))
  }
}

func logInfo(_ message: String) { IO.log("info", message) }
func logWarn(_ message: String) { IO.log("warn", message) }
func logError(_ message: String) { IO.log("error", message) }

enum HelperError: Error, CustomStringConvertible {
  case permission(String)
  case invalidState(String)
  case invalidArgument(String)
  case timeout(String)
  case failed(String)

  var description: String {
    switch self {
    case .permission(let m): return "Permission denied: \(m)"
    case .invalidState(let m): return "Invalid state: \(m)"
    case .invalidArgument(let m): return "Invalid argument: \(m)"
    case .timeout(let m): return "Timed out: \(m)"
    case .failed(let m): return m
    }
  }
}

/// Holds the result of an asynchronous callback so a synchronous caller can
/// wait for it on a semaphore.
final class ResultBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T?
  private var error: Error?

  func set(_ value: T?, _ error: Error?) {
    lock.lock()
    self.value = value
    self.error = error
    lock.unlock()
  }

  func get(_ what: String) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    guard let value else { throw HelperError.failed("\(what) returned no value") }
    return value
  }
}

/// Run a completion-handler based API synchronously with a timeout.
func waitFor<T>(
  _ what: String, timeout: Double = 10,
  _ body: (@escaping (T?, Error?) -> Void) -> Void
) throws -> T {
  let sem = DispatchSemaphore(value: 0)
  let box = ResultBox<T>()

  body { value, error in
    box.set(value, error)
    sem.signal()
  }

  if sem.wait(timeout: .now() + timeout) == .timedOut {
    throw HelperError.timeout(what)
  }

  return try box.get(what)
}
