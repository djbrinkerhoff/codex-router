import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The `control-center-lifecycle.json` record, ported from
/// `apps/control-center/electron/lifecycle-state.mjs`.
///
/// `bin/model-router-tray` and the CI smoke test read it through
/// `Codex Router --query-lifecycle`, so its shape and the query output are a
/// contract with those scripts, not an implementation detail.
public enum LifecycleState {
  public static let queryArgument = "--query-lifecycle"
  public static let version = 1
  static let maximumBytes = 4_096

  public struct Query: Equatable, Sendable {
    public var running: Bool
    public var pid: Int32?
    public var ready: Bool
    public var visible: Bool
    public var updatedAt: String?

    public static let unavailable = Query(running: false, pid: nil, ready: false, visible: false, updatedAt: nil)

    /// One compact JSON object, keys in the order the Electron query wrote.
    public var json: String {
      let pidText = pid.map(String.init) ?? "null"
      let updated = updatedAt.map { "\"\(escape($0))\"" } ?? "null"
      return "{\"version\":\(LifecycleState.version),\"running\":\(running),\"pid\":\(pidText),\"ready\":\(ready),\"visible\":\(visible),\"updatedAt\":\(updated)}"
    }
  }

  public static func path(environment: [String: String], home: URL) -> URL {
    if let explicit = environment["MODEL_ROUTER_CONTROL_CENTER_STATE"], !explicit.isEmpty {
      return URL(fileURLWithPath: explicit).standardizedFileURL
    }
    return RouterLocator.stateDirectory(environment: environment, home: home)
      .appendingPathComponent("control-center-lifecycle.json")
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
  }

  /// Atomically replaces the record: a private temporary file renamed over
  /// the old one, inside a 0700 directory.
  @discardableResult
  public static func write(
    to file: URL,
    pid: Int32 = getpid(),
    ready: Bool,
    visible: Bool,
    now: Date = Date()
  ) throws -> String {
    let updatedAt = timestamp(now)
    let document = "{\"version\":\(version),\"pid\":\(pid),\"ready\":\(ready),\"visible\":\(visible),\"updatedAt\":\"\(updatedAt)\"}\n"
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let temporary = directory.appendingPathComponent(
      ".\(file.lastPathComponent).\(pid).\(Int(now.timeIntervalSince1970 * 1_000)).tmp"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(
      atPath: temporary.path,
      contents: Data(document.utf8),
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw ControlCenterError("Could not write the Control Center lifecycle state.")
    }
    if rename(temporary.path, file.path) != 0 {
      throw ControlCenterError("Could not publish the Control Center lifecycle state.")
    }
    return updatedAt
  }

  /// `kill(pid, 0)`; permission denial still proves the process exists.
  public static func processIsRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }

  public static func query(file: URL, isRunning: (Int32) -> Bool = processIsRunning) -> Query {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let size = (attributes[.size] as? NSNumber)?.intValue,
      size >= 2, size <= maximumBytes,
      let data = FileManager.default.contents(atPath: file.path),
      let value = try? JSONValue.parse(data),
      value["version"]?.double == Double(version),
      let rawPid = value["pid"]?.double,
      rawPid == rawPid.rounded(), rawPid >= 1, rawPid <= Double(Int32.max),
      let ready = value["ready"]?.bool,
      let visible = value["visible"]?.bool,
      let updatedAt = value["updatedAt"]?.string
    else { return .unavailable }
    let pid = Int32(rawPid)
    let running = isRunning(pid)
    return Query(
      running: running,
      pid: running ? pid : nil,
      ready: running && ready,
      visible: running && visible,
      updatedAt: updatedAt
    )
  }
}

private func escape(_ value: String) -> String {
  var result = ""
  for scalar in value.unicodeScalars {
    switch scalar {
    case "\"": result += "\\\""
    case "\\": result += "\\\\"
    default:
      if scalar.value < 0x20 {
        result += String(format: "\\u%04x", scalar.value)
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
  }
  return result
}
