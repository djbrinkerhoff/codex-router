import Foundation

/// An error the Control Center shows to a person. The message is the
/// router's own wording whenever the router produced one.
public struct ControlCenterError: LocalizedError, Equatable, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// A progress or completion notice for one router operation, as the Electron
/// renderer received it over `router-control:operation`.
public struct OperationEvent: Equatable, Sendable {
  public enum Status: String, Sendable { case started, completed, failed }
  public var id: String?
  public var name: String?
  public var action: String
  public var status: Status
  public var message: String?
  public var error: String?

  public init(id: String? = nil, name: String? = nil, action: String, status: Status, message: String? = nil, error: String? = nil) {
    self.id = id
    self.name = name
    self.action = action
    self.status = status
    self.message = message
    self.error = error
  }

  init?(payload: JSONValue) {
    guard let rawStatus = payload["status"]?.string, let status = Status(rawValue: rawStatus) else { return nil }
    self.id = payload["id"]?.string
    self.name = payload["name"]?.string
    self.action = payload["action"]?.string ?? payload["name"]?.string ?? ""
    self.status = status
    self.message = payload["message"]?.string
    self.error = payload["error"]?.string
  }
}

/// Where and how to start `native-bridge.mjs`.
public struct BridgeLaunch: Equatable, Sendable {
  public var node: URL
  public var script: URL
  /// Plays Electron's `process.resourcesPath` for a packaged app.
  public var resourcesPath: URL?
  public var environment: [String: String]
  public var workingDirectory: URL

  public init(node: URL, script: URL, resourcesPath: URL?, environment: [String: String], workingDirectory: URL) {
    self.node = node
    self.script = script
    self.resourcesPath = resourcesPath
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  public var arguments: [String] {
    var result = [script.path]
    if let resourcesPath { result += ["--resources-path", resourcesPath.path] }
    return result
  }
}

/// Splits a byte stream into newline-terminated lines. Kept separate from the
/// process plumbing so the framing is unit-tested on its own.
public struct LineAccumulator: Sendable {
  public static let maximumLineBytes = 64 * 1024 * 1024
  private var buffer = Data()
  public private(set) var overflowed = false

  public init() {}

  public mutating func append(_ chunk: Data) -> [Data] {
    buffer.append(chunk)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer.subdata(in: buffer.startIndex..<newline)
      buffer.removeSubrange(buffer.startIndex...newline)
      if !line.isEmpty { lines.append(line) }
    }
    if buffer.count > Self.maximumLineBytes {
      // A frame this large is not a Control Center snapshot. Drop it rather
      // than grow without bound; the pending call fails when the bridge exits.
      buffer.removeAll(keepingCapacity: false)
      overflowed = true
    }
    return lines
  }
}

/// One decoded line from the bridge.
public enum BridgeMessage: Equatable, Sendable {
  case ready(protocol: Int, methods: [String])
  case operation(OperationEvent)
  case response(id: Int, result: Result<JSONValue, ControlCenterError>)
  case unknown

  public static func decode(_ line: Data) -> BridgeMessage {
    guard let value = try? JSONValue.parse(line) else { return .unknown }
    if let event = value["event"]?.string {
      switch event {
      case "ready":
        return .ready(protocol: value["protocol"]?.int ?? 0, methods: value["methods"]?.strings ?? [])
      case "operation":
        guard let payload = value["payload"], let operation = OperationEvent(payload: payload) else { return .unknown }
        return .operation(operation)
      default:
        return .unknown
      }
    }
    guard let id = value["id"]?.int, let ok = value["ok"]?.bool else { return .unknown }
    if ok { return .response(id: id, result: .success(value["result"] ?? .null)) }
    let message = value["error"]?.text ?? "Operation failed."
    return .response(id: id, result: .failure(ControlCenterError(message)))
  }
}

/// The encoded request line for one call.
public func bridgeRequestLine(id: Int, method: String, params: [String: JSONValue]?) throws -> Data {
  var request: [String: JSONValue] = ["id": JSONValue(id), "method": JSONValue(method)]
  if let params { request["params"] = .object(params) }
  var data = try JSONValue.object(request).encoded()
  data.append(0x0A)
  return data
}

/// Talks to one long-lived `native-bridge.mjs` process.
///
/// The bridge is started lazily and restarted after it exits, so a router
/// update that replaced the checkout under a running window costs one failed
/// call rather than a dead window.
public final class BridgeClient: @unchecked Sendable {
  public static let supportedProtocol = 1

  private let launch: () throws -> BridgeLaunch
  private let lock = NSLock()
  private var process: Process?
  private var input: FileHandle?
  private var accumulator = LineAccumulator()
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var readyWaiters: [CheckedContinuation<Void, Error>] = []
  private var methods: Set<String>?
  private var stderrTail = Data()
  private let eventHandler: @Sendable (OperationEvent) -> Void

  public init(launch: @escaping () throws -> BridgeLaunch, onOperation: @escaping @Sendable (OperationEvent) -> Void) {
    self.launch = launch
    self.eventHandler = onOperation
  }

  deinit { stop() }

  /// Whether the running bridge offers `method`. `nil` before the first
  /// handshake. An older router simply lacks newer operations.
  public func supports(_ method: String) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return methods.map { $0.contains(method) }
  }

  public func call(_ method: String, _ params: [String: JSONValue]? = nil) async throws -> JSONValue {
    try await ensureStarted()
    let (id, line, input) = try prepareCall(method, params)
    return try await withCheckedThrowingContinuation { continuation in
      register(id, continuation)
      do {
        try input.write(contentsOf: line)
      } catch {
        fail(id, ControlCenterError("The Control Center bridge stopped."))
      }
    }
  }

  public func stop() {
    lock.lock()
    let handle = input
    process = nil
    input = nil
    methods = nil
    lock.unlock()
    // Closing stdin asks the bridge to finish any started mutation and exit.
    try? handle?.close()
  }

  // MARK: Synchronous state transitions
  //
  // Every lock is taken and released inside one synchronous function, never
  // across an await.

  private func prepareCall(_ method: String, _ params: [String: JSONValue]?) throws -> (Int, Data, FileHandle) {
    lock.lock()
    defer { lock.unlock() }
    guard let methods, let input else {
      throw ControlCenterError("The Control Center bridge is not running.")
    }
    guard methods.contains(method) else {
      throw ControlCenterError(
        "The installed Codex Router does not offer this action yet. Update the router and reopen the app."
      )
    }
    let id = nextID
    nextID += 1
    do {
      return (id, try bridgeRequestLine(id: id, method: method, params: params), input)
    } catch {
      throw ControlCenterError("The request could not be encoded.")
    }
  }

  private func register(_ id: Int, _ continuation: CheckedContinuation<JSONValue, Error>) {
    lock.lock()
    guard process != nil else {
      // The bridge exited between preparing and registering this call; its
      // exit handler has already failed everything it could see.
      lock.unlock()
      continuation.resume(throwing: ControlCenterError("The Control Center bridge stopped."))
      return
    }
    pending[id] = continuation
    lock.unlock()
  }

  private func fail(_ id: Int, _ error: Error) {
    lock.lock()
    let waiting = pending.removeValue(forKey: id)
    lock.unlock()
    waiting?.resume(throwing: error)
  }

  private enum StartState { case ready, waiting }

  private func ensureStarted() async throws {
    guard try startIfNeeded() == .waiting else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      awaitReady(continuation)
    }
  }

  private func awaitReady(_ continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if methods != nil {
      lock.unlock()
      continuation.resume()
    } else if process == nil {
      lock.unlock()
      continuation.resume(throwing: ControlCenterError("The Control Center bridge stopped."))
    } else {
      readyWaiters.append(continuation)
      lock.unlock()
    }
  }

  private func startIfNeeded() throws -> StartState {
    lock.lock()
    defer { lock.unlock() }
    if process != nil { return methods == nil ? .waiting : .ready }
    let configuration = try launch()
    let child = Process()
    child.executableURL = configuration.node
    child.arguments = configuration.arguments
    child.environment = configuration.environment
    child.currentDirectoryURL = configuration.workingDirectory
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    child.standardInput = stdinPipe
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe
    accumulator = LineAccumulator()
    stderrTail = Data()
    methods = nil
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self?.receive(chunk)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self?.receiveDiagnostics(chunk)
    }
    child.terminationHandler = { [weak self] exited in
      self?.bridgeExited(exited)
    }
    do {
      try child.run()
    } catch {
      throw ControlCenterError("Node.js could not start the Control Center bridge: \(error.localizedDescription)")
    }
    process = child
    input = stdinPipe.fileHandleForWriting
    return .waiting
  }

  private func receive(_ chunk: Data) {
    lock.lock()
    let lines = accumulator.append(chunk)
    lock.unlock()
    for line in lines { handle(BridgeMessage.decode(line)) }
  }

  private func receiveDiagnostics(_ chunk: Data) {
    lock.lock()
    stderrTail.append(chunk)
    if stderrTail.count > 8_192 { stderrTail = stderrTail.suffix(4_096) }
    lock.unlock()
  }

  private func handle(_ message: BridgeMessage) {
    switch message {
    case .ready(let version, let offered):
      lock.lock()
      let waiters = readyWaiters
      readyWaiters.removeAll()
      if version == Self.supportedProtocol {
        methods = Set(offered)
        lock.unlock()
        for waiter in waiters { waiter.resume() }
      } else {
        lock.unlock()
        let error = ControlCenterError(
          "The installed Codex Router speaks a different Control Center bridge protocol. Install the router and app from the same build."
        )
        for waiter in waiters { waiter.resume(throwing: error) }
        stop()
      }
    case .operation(let event):
      eventHandler(event)
    case .response(let id, let result):
      lock.lock()
      let continuation = pending.removeValue(forKey: id)
      lock.unlock()
      switch result {
      case .success(let value): continuation?.resume(returning: value)
      case .failure(let error): continuation?.resume(throwing: error)
      }
    case .unknown:
      break
    }
  }

  private func bridgeExited(_ exited: Process) {
    lock.lock()
    guard process === exited || process == nil else {
      lock.unlock()
      return
    }
    process = nil
    input = nil
    methods = nil
    let calls = pending
    pending.removeAll()
    let waiters = readyWaiters
    readyWaiters.removeAll()
    let diagnostics = String(data: stderrTail, encoding: .utf8)?
      .split(separator: "\n")
      .last { $0.contains("Control Center bridge failed") }
      .map(String.init)
    lock.unlock()
    let error = ControlCenterError(
      diagnostics ?? "The Control Center bridge stopped (status \(exited.terminationStatus))."
    )
    for continuation in calls.values { continuation.resume(throwing: error) }
    for waiter in waiters { waiter.resume(throwing: error) }
  }
}
