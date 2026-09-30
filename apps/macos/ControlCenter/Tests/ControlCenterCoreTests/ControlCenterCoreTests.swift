import Foundation
import XCTest

@testable import ControlCenterCore

final class JSONValueTests: XCTestCase {
  func testLenientAccessors() throws {
    let value = try JSONValue.parse(#"{"a":{"b":[1,"2",true,null]},"s":"  x ","n":"12.5","o":{}}"#)
    XCTAssertEqual(value["a"]?["b"]?[0]?.double, 1)
    XCTAssertEqual(value["a"]?["b"]?[1]?.double, 2, "numeric strings read as numbers, like Number(value)")
    XCTAssertEqual(value["a"]?["b"]?[2]?.bool, true)
    XCTAssertEqual(value["a"]?["b"]?[3]?.isNull, true)
    XCTAssertNil(value["a"]?["b"]?[9])
    XCTAssertEqual(value["s"]?.text, "x")
    XCTAssertEqual(value["n"]?.int, 12)
    XCTAssertEqual(value.value(at: "a", "b")?.items.count, 4)
    XCTAssertNil(value.value(at: "a", "missing", "deeper"))
    XCTAssertTrue(value["o"].truthy)
    XCTAssertFalse(value["missing"].truthy)
    XCTAssertFalse(JSONValue.string("").truthy)
  }

  func testBooleansAreNotNumbers() throws {
    let value = try JSONValue.parse(#"[true, 1, 0, false]"#)
    XCTAssertEqual(value.items, [.bool(true), .number(1), .number(0), .bool(false)])
  }

  func testSettingCreatesIntermediateObjects() {
    let original: JSONValue = ["targets": ["codex": ["modelSettings": ["keep": 1]]]]
    let updated = original.setting(["status": "downloading"], at: ["targets", "codex", "modelSettings", "localModels"])
    XCTAssertEqual(updated.value(at: "targets", "codex", "modelSettings", "keep")?.double, 1)
    XCTAssertEqual(updated.value(at: "targets", "codex", "modelSettings", "localModels", "status")?.string, "downloading")
    XCTAssertNil(original.value(at: "targets", "codex", "modelSettings", "localModels"), "the original is unchanged")
  }
}

final class BridgeFramingTests: XCTestCase {
  func testLineAccumulatorSplitsAcrossChunks() {
    var accumulator = LineAccumulator()
    XCTAssertEqual(accumulator.append(Data("{\"a\":".utf8)), [])
    let lines = accumulator.append(Data("1}\n\n{\"b\":2}\n{\"c\"".utf8))
    XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
    XCTAssertEqual(accumulator.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
  }

  func testDecodesEveryBridgeMessage() {
    XCTAssertEqual(
      BridgeMessage.decode(Data(#"{"event":"ready","protocol":1,"methods":["getProviders"]}"#.utf8)),
      .ready(version: 1, methods: ["getProviders"])
    )
    XCTAssertEqual(
      BridgeMessage.decode(Data(#"{"event":"operation","payload":{"id":"x","name":"setPresence","status":"failed","message":"m","error":"e"}}"#.utf8)),
      .operation(OperationEvent(id: "x", name: "setPresence", action: "setPresence", status: .failed, message: "m", error: "e"))
    )
    XCTAssertEqual(
      BridgeMessage.decode(Data(#"{"id":3,"ok":true,"result":{"k":1}}"#.utf8)),
      .response(id: 3, result: .success(["k": 1]))
    )
    XCTAssertEqual(
      BridgeMessage.decode(Data(#"{"id":4,"ok":false,"error":"Presence mode must be one of: always, follow-codex."}"#.utf8)),
      .response(id: 4, result: .failure(ControlCenterError("Presence mode must be one of: always, follow-codex.")))
    )
    XCTAssertEqual(BridgeMessage.decode(Data("not json".utf8)), .unknown)
    XCTAssertEqual(BridgeMessage.decode(Data(#"{"event":"operation","payload":{"status":"weird"}}"#.utf8)), .unknown)
  }

  func testRequestLineCarriesParamsOnlyWhenGiven() throws {
    let bare = try JSONValue.parse(try bridgeRequestLine(id: 7, method: "getHealth", params: nil))
    XCTAssertEqual(bare, ["id": 7, "method": "getHealth"])
    let line = try bridgeRequestLine(id: 8, method: "saveProviderCredential", params: ["providerId": "opencode-go", "credential": "k"])
    XCTAssertEqual(line.last, 0x0A, "each request is one line")
    XCTAssertEqual(try JSONValue.parse(line)["params"]?["providerId"]?.string, "opencode-go")
  }
}

final class BridgeClientTests: XCTestCase {
  /// Runs a stand-in bridge that speaks the real wire format.
  private func fakeBridge(_ script: String) throws -> (BridgeClient, URL) {
    guard let node = RouterLocator.nodeExecutable(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    ) else {
      throw XCTSkip("Node.js is not installed")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("bridge.mjs")
    try script.write(to: file, atomically: true, encoding: .utf8)
    let launch = BridgeLaunch(node: node, script: file, resourcesPath: nil, environment: ProcessInfo.processInfo.environment, workingDirectory: directory)
    let client = BridgeClient(launch: { launch }, onOperation: { _ in })
    return (client, directory)
  }

  func testConcurrentCallsResolveByID() async throws {
    let (client, directory) = try fakeBridge("""
      import readline from "node:readline";
      const send = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
      send({ event: "ready", protocol: 1, methods: ["echo", "fail"] });
      readline.createInterface({ input: process.stdin }).on("line", (line) => {
        const request = JSON.parse(line);
        const delay = request.params?.delay ?? 0;
        setTimeout(() => {
          if (request.method === "fail") send({ id: request.id, ok: false, error: "refused" });
          else send({ id: request.id, ok: true, result: request.params });
        }, delay);
      });
      """)
    defer {
      client.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    async let slow = client.call("echo", ["delay": 150, "tag": "slow"])
    async let fast = client.call("echo", ["delay": 0, "tag": "fast"])
    let (slowValue, fastValue) = try await (slow, fast)
    XCTAssertEqual(slowValue["tag"]?.string, "slow")
    XCTAssertEqual(fastValue["tag"]?.string, "fast")
    XCTAssertEqual(client.supports("echo"), true)
    XCTAssertEqual(client.supports("closeWindow"), false)
    do {
      _ = try await client.call("fail")
      XCTFail("a refused call throws")
    } catch let error as ControlCenterError {
      XCTAssertEqual(error.message, "refused")
    }
    do {
      _ = try await client.call("notOffered")
      XCTFail("an operation the bridge did not announce is refused locally")
    } catch let error as ControlCenterError {
      XCTAssertTrue(error.message.contains("does not offer"))
    }
  }

  func testExitFailsPendingCallsAndRestarts() async throws {
    let (client, directory) = try fakeBridge("""
      import readline from "node:readline";
      const send = (value) => process.stdout.write(JSON.stringify(value) + "\\n");
      send({ event: "ready", protocol: 1, methods: ["die", "echo"] });
      readline.createInterface({ input: process.stdin }).on("line", (line) => {
        const request = JSON.parse(line);
        if (request.method === "die") process.exit(3);
        send({ id: request.id, ok: true, result: "alive" });
      });
      """)
    defer {
      client.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    do {
      _ = try await client.call("die")
      XCTFail("a bridge that exits fails the call")
    } catch {
      XCTAssertTrue(error is ControlCenterError)
    }
    // Give the termination handler a moment, then the next call starts a
    // fresh bridge.
    try await Task.sleep(nanoseconds: 200_000_000)
    let value = try await client.call("echo")
    XCTAssertEqual(value.string, "alive")
  }
}

final class LifecycleStateTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testPathFollowsTheRouterStateDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    XCTAssertEqual(
      LifecycleState.path(environment: [:], home: home).path,
      "/Users/example/.codex/codex-router/control-center-lifecycle.json"
    )
    XCTAssertEqual(
      LifecycleState.path(environment: ["CODEX_HOME": "/tmp/codex"], home: home).path,
      "/tmp/codex/codex-router/control-center-lifecycle.json"
    )
    XCTAssertEqual(
      LifecycleState.path(environment: ["MODEL_ROUTER_STATE_DIR": "/tmp/state", "CODEX_HOME": "/tmp/codex"], home: home).path,
      "/tmp/state/control-center-lifecycle.json"
    )
    XCTAssertEqual(
      LifecycleState.path(environment: ["MODEL_ROUTER_CONTROL_CENTER_STATE": "/tmp/explicit.json"], home: home).path,
      "/tmp/explicit.json"
    )
  }

  func testWriteThenQueryRoundTrips() throws {
    let file = directory.appendingPathComponent("control-center-lifecycle.json")
    try LifecycleState.write(to: file, pid: 4242, ready: true, visible: false)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let running = LifecycleState.query(file: file, isRunning: { $0 == 4242 })
    XCTAssertEqual(running.running, true)
    XCTAssertEqual(running.pid, 4242)
    XCTAssertEqual(running.ready, true)
    XCTAssertEqual(running.visible, false)
    let stale = LifecycleState.query(file: file, isRunning: { _ in false })
    XCTAssertEqual(stale.running, false)
    XCTAssertNil(stale.pid)
    XCTAssertEqual(stale.ready, false, "a dead owner is never ready")
    XCTAssertNotNil(stale.updatedAt)
  }

  func testQueryOutputIsTheElectronShape() throws {
    let file = directory.appendingPathComponent("state.json")
    try LifecycleState.write(to: file, pid: 7, ready: true, visible: true, now: Date(timeIntervalSince1970: 0))
    let json = try JSONValue.parse(LifecycleState.query(file: file, isRunning: { _ in true }).json)
    XCTAssertEqual(json, [
      "version": 1, "running": true, "pid": 7, "ready": true, "visible": true,
      "updatedAt": "1970-01-01T00:00:00.000Z",
    ])
    XCTAssertEqual(
      try JSONValue.parse(LifecycleState.Query.unavailable.json),
      ["version": 1, "running": false, "pid": nil, "ready": false, "visible": false, "updatedAt": nil]
    )
  }

  func testMalformedRecordsReadAsUnavailable() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("state.json")
    for document in [
      "{}",
      #"{"version":2,"pid":1,"ready":true,"visible":true,"updatedAt":"x"}"#,
      #"{"version":1,"pid":0,"ready":true,"visible":true,"updatedAt":"x"}"#,
      #"{"version":1,"pid":1.5,"ready":true,"visible":true,"updatedAt":"x"}"#,
      #"{"version":1,"pid":1,"ready":"yes","visible":true,"updatedAt":"x"}"#,
      String(repeating: " ", count: 5_000),
    ] {
      try document.write(to: file, atomically: true, encoding: .utf8)
      XCTAssertEqual(LifecycleState.query(file: file, isRunning: { _ in true }), .unavailable, document)
    }
    XCTAssertEqual(LifecycleState.query(file: directory.appendingPathComponent("missing.json")), .unavailable)
  }
}

final class NavigationRequestTests: XCTestCase {
  func testArguments() {
    XCTAssertEqual(NavigationRequest(arguments: ["app", "--router-destination", "usage"]), NavigationRequest(destination: .usage))
    XCTAssertEqual(
      NavigationRequest(arguments: ["--router-destination", "usage-resets", "--router-source", "opencode-go"]),
      NavigationRequest(destination: .usageResets, sourceID: "opencode-go")
    )
    XCTAssertNil(NavigationRequest(arguments: ["--router-destination", "settings"]))
    XCTAssertNil(NavigationRequest(arguments: ["--router-destination", "usage", "--router-destination", "usage"]))
    XCTAssertNil(NavigationRequest(arguments: ["--router-destination", "usage", "--router-source", "Bad_ID"]))
    XCTAssertNil(NavigationRequest(arguments: ["--router-destination"]))
    XCTAssertNil(NavigationRequest(arguments: []))
  }

  func testURLs() {
    XCTAssertEqual(NavigationRequest(url: URL(string: "codex-router://control-center/usage")!), NavigationRequest(destination: .usage))
    XCTAssertEqual(
      NavigationRequest(url: URL(string: "codex-router://control-center/usage-resets?source=kimi-oauth")!),
      NavigationRequest(destination: .usageResets, sourceID: "kimi-oauth")
    )
    for invalid in [
      "https://control-center/usage",
      "codex-router://other/usage",
      "codex-router://control-center/settings",
      "codex-router://user@control-center/usage",
      "codex-router://control-center:9/usage",
      "codex-router://control-center/usage#x",
      "codex-router://control-center/usage?source=a&source=b",
      "codex-router://control-center/usage?other=a",
      "codex-router://control-center/usage?source=-leading",
    ] {
      XCTAssertNil(NavigationRequest(url: URL(string: invalid)!), invalid)
    }
  }
}

final class LocalizationTests: XCTestCase {
  func testCatalogsLoadFromTheResourceBundle() {
    let catalogs = StringCatalogs.shared
    XCTAssertTrue(catalogs.isLanguage("en"))
    XCTAssertTrue(catalogs.isLanguage("zh-CN"))
    XCTAssertTrue(catalogs.isLanguage("zh-TW"))
    XCTAssertEqual(Translator(language: "en")("common.refresh"), "Refresh")
    XCTAssertEqual(Translator(language: "zh-CN")("common.refresh"), "刷新")
  }

  func testInterpolationIsOnePassAndLeavesUnknownTokens() {
    XCTAssertEqual(Translator.interpolate("{count} of {total}", ["count": 3]), "3 of {total}")
    XCTAssertEqual(Translator.interpolate("{a}", ["a": "{a}"]), "{a}", "inserted values are not templates")
    XCTAssertEqual(Translator.interpolate("no tokens", ["a": 1]), "no tokens")
    XCTAssertEqual(Translator.interpolate("{not valid}", [:]), "{not valid}")
  }

  func testUnknownIDsFallBackToEnglishThenTheID() {
    XCTAssertEqual(Translator(language: "ja")("common.refresh"), Translator(language: "en")("common.refresh"))
    XCTAssertEqual(Translator(language: "en")("no.such.id"), "no.such.id")
    XCTAssertEqual(Translator(language: "xx").language, "en")
  }

  func testResolveLanguage() {
    let catalogs = StringCatalogs.shared
    XCTAssertEqual(catalogs.resolveLanguage("zh-Hans-TW"), "zh-CN")
    XCTAssertEqual(catalogs.resolveLanguage("zh-Hant-CN"), "zh-TW")
    XCTAssertEqual(catalogs.resolveLanguage("zh-HK"), "zh-TW")
    XCTAssertEqual(catalogs.resolveLanguage("zh"), "zh-CN")
    XCTAssertEqual(catalogs.resolveLanguage("zh-Latn"), "en")
    XCTAssertEqual(catalogs.resolveLanguage("ja_JP"), "ja")
    XCTAssertEqual(catalogs.resolveLanguage("fr-FR"), "en")
    XCTAssertEqual(catalogs.resolveLanguage(nil), "en")
  }

  func testBackendTextIsTranslatedOnlyForChinese() {
    let english = Translator(language: "en")
    XCTAssertEqual(english.backend("Refresh"), "Refresh")
    let chinese = Translator(language: "zh-CN")
    XCTAssertEqual(chinese.backend("Refresh"), "刷新")
    XCTAssertEqual(chinese.backend("an unrecognized router message"), "an unrecognized router message")
    XCTAssertEqual(
      chinese.backend("Official Ollama · 12 tags"),
      chinese("backend.ollamaCatalogTags", ["count": "12"])
    )
  }
}

final class FormatTests: XCTestCase {
  let t = Translator(language: "en")

  func testCompactNumbers() {
    XCTAssertEqual(Format.compactNumber(999, t), "999")
    XCTAssertEqual(Format.compactNumber(1_500, t), "1.5k")
    XCTAssertEqual(Format.compactNumber(12_000, t), "12k")
    XCTAssertEqual(Format.compactNumber(2_000_000, t), "2m")
    XCTAssertEqual(Format.compactNumber(3_400_000_000, t), "3.4b")
    XCTAssertEqual(Format.compactNumber(-5, t), "0")
    XCTAssertEqual(Format.compactNumber(nil, t), "0")
  }

  func testEffortLabels() {
    XCTAssertEqual(Format.effortLabel("high", t), "high")
    XCTAssertEqual(Format.effortLabel("future-rung", t), "future-rung")
    let chinese = Translator(language: "zh-CN")
    XCTAssertTrue(Format.effortLabel("high", chinese).hasSuffix("(high)"))
  }

  func testMetricValues() {
    XCTAssertEqual(Format.metricValue(["remainingPercent": 42.4], t), "42% left")
    XCTAssertEqual(Format.metricValue(["usedPercent": 30], t), "70% left")
    XCTAssertEqual(Format.metricValue(["remaining": 1_500], t), "1.5k left")
    XCTAssertEqual(Format.metricValue([:], t), "Reported")
    XCTAssertTrue(Format.metricValue(["kind": "balance", "value": 12.5, "currency": "DIEM"], t).hasSuffix("DIEM"))
    XCTAssertEqual(Format.remainingPercent(["remaining": 25, "limit": 100]), 25)
    XCTAssertEqual(Format.remainingPercent(["remainingPercent": 140]), 100)
    XCTAssertNil(Format.remainingPercent(["limit": 100]))
  }

  func testBucketRangeWalksUTCDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 1))!
    let buckets: [JSONValue] = [["startDate": "2026-09-29", "tokens": 10]]
    let range = Format.bucketRange(buckets, days: 3, now: now)
    XCTAssertEqual(range.map(\.startDate), ["2026-09-28", "2026-09-29", "2026-09-30"])
    XCTAssertEqual(range.map(\.tokens), [0, 10, 0])
  }

  func testAccountBucketsWinOverRouterFallback() {
    let merged = Format.accountBucketsWithRouterFallback(
      account: [["startDate": "2026-09-02", "tokens": 5]],
      router: [["startDate": "2026-09-01", "tokens": 1], ["startDate": "2026-09-02", "tokens": 99]]
    )
    XCTAssertEqual(merged.map(\.startDate), ["2026-09-01", "2026-09-02"])
    XCTAssertEqual(merged.map(\.tokens), [1, 5])
    XCTAssertEqual(merged.map(\.fromRouterFallback), [true, false])
  }

  func testDates() {
    XCTAssertEqual(Format.date(.number(1_000))?.timeIntervalSince1970, 1_000)
    XCTAssertEqual(Format.date(.number(1_700_000_000_000))?.timeIntervalSince1970, 1_700_000_000)
    XCTAssertNotNil(Format.date("2026-09-30T12:00:00.000Z"))
    XCTAssertNotNil(Format.date("2026-09-30"))
    XCTAssertNil(Format.date("not a date"))
    XCTAssertEqual(Format.dateTime(nil, t), "Not reported")
  }
}

final class RouterLocatorTests: XCTestCase {
  func testSearchPathPutsUserInstallsFirstWithoutDuplicates() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let path = RouterLocator.searchPath(environment: ["PATH": "/usr/local/bin:/usr/bin"], home: home)
    XCTAssertEqual(path.first, "/Users/example/.npm-global/bin")
    XCTAssertEqual(path.filter { $0 == "/usr/local/bin" }.count, 1)
    XCTAssertEqual(path.last, "/usr/bin")
  }

  func testExplicitNodeWinsOnlyWhenExecutable() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let executable: Set<String> = ["/opt/node/bin/node", "/opt/homebrew/bin/node"]
    XCTAssertEqual(
      RouterLocator.nodeExecutable(environment: ["CODEX_ROUTER_NODE_BIN": "/opt/node/bin/node"], home: home, isExecutable: executable.contains)?.path,
      "/opt/node/bin/node"
    )
    XCTAssertEqual(
      RouterLocator.nodeExecutable(environment: ["CODEX_ROUTER_NODE_BIN": "relative/node"], home: home, isExecutable: executable.contains)?.path,
      "/opt/homebrew/bin/node"
    )
    XCTAssertNil(RouterLocator.nodeExecutable(environment: ["PATH": "/nowhere"], home: home, isExecutable: { _ in false }))
  }

  func testBundledBridgeIsPreferred() throws {
    let resources = URL(fileURLWithPath: "/App/Contents/Resources", isDirectory: true)
    let script = "/App/Contents/Resources/bridge/apps/control-center/electron/native-bridge.mjs"
    XCTAssertEqual(RouterLocator.bundledBridge(resources: resources, fileExists: { $0 == script })?.path, script)
    XCTAssertNil(RouterLocator.bundledBridge(resources: resources, fileExists: { _ in false }))
  }

  func testCheckoutBridgeWalksUpFromTheBuildDirectory() {
    let executable = URL(fileURLWithPath: "/src/codex-router/apps/macos/ControlCenter/.build/arm64-apple-macosx/debug/ControlCenter")
    let expected = "/src/codex-router/apps/control-center/electron/native-bridge.mjs"
    XCTAssertEqual(
      RouterLocator.checkoutBridge(environment: [:], executable: executable, fileExists: { $0 == expected })?.path,
      expected
    )
  }
}
