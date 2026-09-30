import ControlCenterCore
import Foundation

// The Status page's data model, ported from the pure functions in
// `StatusPage.tsx`.

let statusModelPageSize = 12

/// The compaction-savings ranges (`CONTEXT_SAVINGS_RANGES`). The labels are
/// the renderer's own literals.
enum StatusSavingsRange: String, CaseIterable, Identifiable {
  case day = "24h"
  case week = "7d"
  case month = "30d"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .day: return "24H"
    case .week: return "7D"
    case .month: return "30D"
    }
  }

  var bucketLabel: String {
    switch self {
    case .day: return "hour"
    case .week, .month: return "day"
    }
  }
}

struct StatusModelUsage: Identifiable {
  let id: String
  let providerID: String
  let providerName: String
  let slug: String?
  let displayName: String?
  let inputTokens: Double?
  let outputTokens: Double?
  let totalTokens: Double?
  let requests: Double?
  let speed: Double?
  let speedSamples: Double?

  /// `displayName || slug`.
  var title: String? { UsageLogic.nonEmpty(displayName) ?? UsageLogic.nonEmpty(slug) }
}

struct StatusResetRow: Identifiable {
  let id: String
  let providerID: String
  let provider: String
  let label: String
  let remaining: Double?
  let resetValue: JSONValue
  /// Milliseconds since the epoch, when the value is readable.
  let timestamp: Double?
}

struct StatusSummaryEntry: Identifiable {
  var id: String { label }
  let label: String
  let value: String
  let detail: String
  var tone: Tone?
  var pending = false
}

struct StatusContextWindow: Identifiable {
  var id: String { label }
  let label: String
  let value: Double?
}

/// Everything the page derives from the router's data for one render.
struct StatusData {
  var healthPending = false
  var snapshotPending = false
  var providerUsagePending = false
  /// `!providerUsage`: no usage snapshot has arrived yet.
  var providerUsageMissing = true
  /// The context panel's loading partition.
  var contextPending = false
  var usagePending = false
  var state = "offline"
  var active: [JSONValue] = []
  var activeRequestCount = 0
  var allModelRows: [StatusModelUsage] = []
  var speedRows: [StatusModelUsage] = []
  var events: [JSONValue] = []
  var recentEvents: [JSONValue] = []
  var hasCacheTelemetry = false
  var cachedInputTokens = 0.0
  var observedInputTokens = 0.0
  var cacheReusePercent: Double?
  var estimatedInputEvents = 0
  var contextWindows: [StatusContextWindow] = []
  var compactionStats: JSONValue?
  var resetRows: [StatusResetRow] = []
  var summary: [StatusSummaryEntry] = []
}

enum StatusLogic {
  // MARK: Text helpers

  /// A JavaScript `||` chain over string fields: the first non-empty one.
  static func firstText(_ json: JSONValue, _ keys: [String]) -> String? {
    for key in keys {
      if let value = json[key]?.string, !value.isEmpty { return value }
    }
    return nil
  }

  static func uniqueCount(_ values: [String?]) -> Int {
    var seen = Set<String>()
    for value in values {
      if let value, !value.isEmpty { seen.insert(value) }
    }
    return seen.count
  }

  static func shortModelName(_ model: String) -> String {
    let parts = model.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    return parts.last ?? model
  }

  static func requestSessionName(_ request: JSONValue) -> String? {
    firstText(request, ["sessionName", "sessionTitle"])
  }

  static func isAgent(_ request: JSONValue) -> Bool {
    request["isSubagent"]?.bool == true
      || firstText(request, ["agentName"]) != nil
      || firstText(request, ["agentNickname"]) != nil
  }

  static func requestTitle(_ request: JSONValue, _ t: Translator) -> String {
    if let nickname = firstText(request, ["agentNickname", "agentName"]) { return nickname }
    if let session = requestSessionName(request) { return session }
    if let model = UsageLogic.nonEmpty(request["model"]?.string) { return shortModelName(model) }
    return t("status.request.routedRequest")
  }

  static func activityLabel(_ state: String, _ t: Translator) -> String {
    switch state {
    case "generating": return t("status.activity.thinking")
    case "starting": return t("status.activity.starting")
    case "error": return t("status.activity.error")
    case "offline": return t("status.activity.offline")
    default: return t("status.activity.idle")
    }
  }

  static func requestActivityLabel(_ state: String, _ t: Translator) -> String {
    state == "idle" ? t("status.activity.working") : activityLabel(state, t)
  }

  // MARK: Time

  static func nowMilliseconds() -> Double { Date().timeIntervalSince1970 * 1_000 }

  /// Seconds-or-milliseconds epoch numbers and ISO strings, as milliseconds.
  static func timestampMs(_ value: JSONValue) -> Double? {
    if let number = value.double { return number < 10_000_000_000 ? number * 1_000 : number }
    if let date = Format.date(value) { return date.timeIntervalSince1970 * 1_000 }
    return nil
  }

  static func elapsedFrom(_ startedAt: JSONValue?) -> Double {
    guard let startedAt, !startedAt.isNull, let start = timestampMs(startedAt) else { return 0 }
    return max(0, nowMilliseconds() - start)
  }

  static func liveElapsedLabel(_ request: JSONValue) -> String {
    let milliseconds = request["elapsedMs"]?.double ?? elapsedFrom(request["startedAt"])
    let seconds = Int(max(0, milliseconds) / 1_000)
    if seconds < 60 { return "\(seconds)s" }
    return "\(seconds / 60)m \(seconds % 60)s"
  }

  static func resetCountdown(_ timestamp: Double?, _ t: Translator) -> String {
    guard let timestamp, timestamp.isFinite else { return t("status.countdown.unavailable") }
    let remaining = timestamp - nowMilliseconds()
    if remaining <= 0 { return t("status.countdown.refreshDue") }
    let minutes = Int((remaining / 60_000).rounded(.up))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    return "\(hours / 24)d \(hours % 24)h"
  }

  // MARK: Models

  static func modelRows(_ providerUsage: JSONValue?) -> [StatusModelUsage] {
    var rows: [StatusModelUsage] = []
    var used: [String: Int] = [:]
    for provider in providerUsage?["providers"]?.items ?? [] {
      let providerID = provider["id"]?.string ?? ""
      let providerName = provider["displayName"]?.string ?? providerID
      for model in provider["models"]?.items ?? [] {
        let slug = model["slug"]?.string
        let displayName = model["displayName"]?.string
        let base = "\(providerID)/\(UsageLogic.nonEmpty(slug) ?? displayName ?? "")"
        let seen = used[base, default: 0]
        used[base] = seen + 1
        rows.append(StatusModelUsage(
          id: seen == 0 ? base : "\(base)#\(seen)",
          providerID: providerID,
          providerName: providerName,
          slug: slug,
          displayName: displayName,
          inputTokens: model["inputTokens"]?.double,
          outputTokens: model["outputTokens"]?.double,
          totalTokens: model["totalTokens"]?.double,
          requests: model["requests"]?.double,
          speed: model["observedTokensPerSecond"]?.double,
          speedSamples: model["speedSampleCount"]?.double
        ))
      }
    }
    return rows
  }

  static func modelUsageOrder(_ left: StatusModelUsage, _ right: StatusModelUsage) -> Bool {
    let leftTotal = left.totalTokens ?? 0
    let rightTotal = right.totalTokens ?? 0
    if leftTotal != rightTotal { return leftTotal > rightTotal }
    let leftRequests = left.requests ?? 0
    let rightRequests = right.requests ?? 0
    if leftRequests != rightRequests { return leftRequests > rightRequests }
    let leftName = left.title ?? ""
    let rightName = right.title ?? ""
    let byName = leftName.localizedCompare(rightName)
    if byName != .orderedSame { return byName == .orderedAscending }
    return left.providerName.localizedCompare(right.providerName) == .orderedAscending
  }

  static func speedOrder(_ left: StatusModelUsage, _ right: StatusModelUsage) -> Bool {
    let leftSpeed = left.speed ?? 0
    let rightSpeed = right.speed ?? 0
    if leftSpeed != rightSpeed { return leftSpeed > rightSpeed }
    return (left.speedSamples ?? 0) > (right.speedSamples ?? 0)
  }

  // MARK: Quota resets

  static func resetValue(_ metric: JSONValue) -> JSONValue? {
    if let value = metric["resetAt"], value.truthy { return value }
    if let value = metric["resetsAt"], value.truthy { return value }
    return nil
  }

  static func buildResetRows(_ t: Translator, account: JSONValue?, providerUsage: JSONValue?) -> [StatusResetRow] {
    var rows: [StatusResetRow] = []
    let windows: [JSONValue?] = [account?["primary"], account?["secondary"]]
    for (index, window) in windows.enumerated() {
      guard let window, window.object != nil, let resetAt = resetValue(window) else { continue }
      rows.append(StatusResetRow(
        id: "chatgpt-\(index)",
        providerID: "openai",
        provider: "ChatGPT",
        label: UsageLogic.limitWindowLabel(window["windowDurationMins"]?.double, index: index, t),
        remaining: Format.remainingPercent(window),
        resetValue: resetAt,
        timestamp: timestampMs(resetAt)
      ))
    }
    for provider in providerUsage?["providers"]?.items ?? [] {
      let providerID = provider["id"]?.string ?? ""
      let providerName = provider["displayName"]?.string ?? providerID
      for (index, metric) in (provider["account"]?["metrics"]?.items ?? []).enumerated() {
        guard let resetAt = resetValue(metric) else { continue }
        let rawLabel = metric["label"]?.string
        let label = t.backend(rawLabel)
        rows.append(StatusResetRow(
          id: "\(providerID)-\(index)-\(rawLabel ?? "")",
          providerID: providerID,
          provider: providerName,
          label: label.isEmpty ? t("status.usageLimit") : label,
          remaining: Format.remainingPercent(metric),
          resetValue: resetAt,
          timestamp: timestampMs(resetAt)
        ))
      }
    }
    let now = nowMilliseconds()
    let ordered = rows.enumerated().sorted { left, right in
      let leftTime = left.element.timestamp ?? Double.infinity
      let rightTime = right.element.timestamp ?? Double.infinity
      let leftPast = leftTime <= now
      let rightPast = rightTime <= now
      if leftPast != rightPast { return !leftPast }
      if leftTime != rightTime { return leftTime < rightTime }
      return left.offset < right.offset
    }
    return ordered.map { $0.element }
  }

  // MARK: Context efficiency

  static func cachedTokensForCalendarDays(_ daily: [JSONValue], days: Int, hasTelemetry: Bool) -> Double? {
    if daily.isEmpty { return hasTelemetry ? 0 : nil }
    // Bucket keys are UTC days, so the window bounding them has to be as well.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -max(0, days - 1), to: today) ?? today
    var total = 0.0
    for bucket in daily {
      guard let key = bucket["startDate"]?.string, let date = Format.date(.string("\(key)T00:00:00Z")) else { continue }
      if date < start || date > now { continue }
      total += max(0, bucket["cachedInputTokens"]?.double ?? 0)
    }
    return total
  }

  static func contextWindows(daily: [JSONValue], last24h: Double?, hasTelemetry: Bool, _ t: Translator) -> [StatusContextWindow] {
    [
      StatusContextWindow(
        label: t("status.context.window.24h"),
        value: last24h ?? cachedTokensForCalendarDays(daily, days: 1, hasTelemetry: hasTelemetry)
      ),
      StatusContextWindow(
        label: t("status.context.window.7d"),
        value: cachedTokensForCalendarDays(daily, days: 7, hasTelemetry: hasTelemetry)
      ),
      StatusContextWindow(
        label: t("status.context.window.30d"),
        value: cachedTokensForCalendarDays(daily, days: 30, hasTelemetry: hasTelemetry)
      ),
    ]
  }

  static func eventFlag(_ event: JSONValue, _ t: Translator) -> String? {
    if event["streamAborted"].truthy { return t("status.flag.truncated") }
    if let limit = UsageLogic.nonEmpty(event["emptyCompletionPreludeLimit"]?.string) {
      return t("status.flag.guardLimit", ["limit": limit])
    }
    if event["emptyCompletionRetried"].truthy { return t("status.flag.retriedEmpty") }
    if event["emptyCompletion"].truthy { return t("status.flag.emptyReply") }
    if event["emptyCompletionGuardReleased"].truthy { return t("status.flag.guardReleased") }
    if let retries = event["retries"]?.double, retries != 0 {
      let count = Int(retries.rounded())
      return retries == 1 ? t("status.flag.retryOne", ["count": count]) : t("status.flag.retryMany", ["count": count])
    }
    if UsageLogic.present(event["estimatedInputTokens"]) { return t("status.flag.estimatedInput") }
    return nil
  }

  // MARK: Build

  static func build(
    _ t: Translator,
    target: JSONValue?,
    health: JSONValue?,
    account: JSONValue?,
    providerUsage: JSONValue?,
    refreshing: Bool,
    ready: (DataSource) -> Bool
  ) -> StatusData {
    var data = StatusData()
    data.healthPending = !ready(.health) && health == nil
    data.snapshotPending = !ready(.snapshot) && target == nil
    data.providerUsageMissing = providerUsage == nil
    data.providerUsagePending = !ready(.providerUsage) && providerUsage == nil
    data.contextPending = data.snapshotPending && data.providerUsageMissing
    data.usagePending = (!ready(.accountUsage) && account == nil) || data.providerUsagePending

    applyLive(&data, health: health, refreshing: refreshing)
    applyModels(&data, providerUsage: providerUsage)
    applyContext(&data, t, target: target, providerUsage: providerUsage)
    data.resetRows = buildResetRows(t, account: account, providerUsage: providerUsage)
    data.summary = buildSummary(t, data: data, health: health, refreshing: refreshing)
    return data
  }

  private static func applyLive(_ data: inout StatusData, health: JSONValue?, refreshing: Bool) {
    let activity = health?["activity"]
    data.active = activity?["active"]?.items ?? []
    data.activeRequestCount = activity?["activeCount"]?.int ?? data.active.count
    if let health {
      let ok = health["ok"].truthy
      data.state = ok ? (UsageLogic.nonEmpty(activity?["state"]?.string) ?? "idle") : "offline"
    } else {
      data.state = refreshing ? "starting" : "offline"
    }
  }

  private static func applyModels(_ data: inout StatusData, providerUsage: JSONValue?) {
    let rows = modelRows(providerUsage)
    data.speedRows = rows.filter { $0.speed != nil }.sorted(by: speedOrder)
    data.allModelRows = rows.sorted(by: modelUsageOrder)
  }

  private static func applyContext(_ data: inout StatusData, _ t: Translator, target: JSONValue?, providerUsage: JSONValue?) {
    let events = target?["usageEvents"]?.items ?? []
    data.events = events
    data.recentEvents = Array(events.reversed().prefix(12))
    let hasEventCacheTelemetry = events.contains { ($0.object?.keys.contains("cachedInputTokens")) ?? false }
    let efficiency = providerUsage?["contextEfficiency"]
    let daily = efficiency?["dailyCachedInputTokens"]?.items ?? []
    let reportedLast24h = efficiency?["last24hCachedInputTokens"]
    let hasReportedLast24h = UsageLogic.present(reportedLast24h)
    data.hasCacheTelemetry = hasEventCacheTelemetry || hasReportedLast24h || !daily.isEmpty
    let eventCached = events.reduce(0.0) { $0 + ($1["cachedInputTokens"]?.double ?? 0) }
    data.cachedInputTokens = reportedLast24h?.double ?? eventCached
    data.observedInputTokens = events.reduce(0.0) { $0 + ($1["inputTokens"]?.double ?? 0) }
    data.cacheReusePercent = data.observedInputTokens > 0
      ? min(100, data.cachedInputTokens / data.observedInputTokens * 100)
      : nil
    data.estimatedInputEvents = events.filter { $0["estimatedInputTokens"]?.double != nil }.count
    let windowLast24h: Double? = reportedLast24h?.double ?? (hasEventCacheTelemetry ? eventCached : nil)
    data.contextWindows = contextWindows(daily: daily, last24h: windowLast24h, hasTelemetry: data.hasCacheTelemetry, t)
    data.compactionStats = target?["modelSettings"]?["toolResultAging"]?["stats"]
  }

  private static func buildSummary(_ t: Translator, data: StatusData, health: JSONValue?, refreshing: Bool) -> [StatusSummaryEntry] {
    let chatCount = uniqueCount(data.active.map { request in
      firstText(request, ["sessionId", "sessionName", "sessionTitle", "threadId", "id"])
    })
    let agents = data.active.filter { isAgent($0) }
    let runningAgentCount = uniqueCount(agents.map { request -> String? in
      if let thread = firstText(request, ["threadId"]) { return thread }
      let session = firstText(request, ["sessionId", "sessionName"]) ?? "session"
      let name = firstText(request, ["agentNickname", "agentName"]) ?? ""
      return "\(session):\(name)"
    })
    let fastest = data.speedRows.first
    let nextReset = data.resetRows.first(where: { ($0.timestamp ?? -Double.infinity) > nowMilliseconds() }) ?? data.resetRows.first

    var healthOK = false
    if let health { healthOK = health["ok"].truthy }
    var routerValue = t("status.summary.unavailable")
    var routerDetail = t("status.summary.localHealthEndpoint")
    if let health {
      routerValue = healthOK ? t("status.summary.online") : t("status.summary.offline")
      if let version = UsageLogic.nonEmpty(health["version"]?.string) {
        routerDetail = t("status.summary.version", ["version": version])
      } else if let error = UsageLogic.nonEmpty(health["error"]?.string) {
        routerDetail = error
      }
    } else if refreshing {
      routerValue = t("status.summary.checking")
    }

    var speedValue = t("status.summary.unmeasured")
    var speedDetail = t("status.summary.afterMeteredReply")
    if let fastest, let speed = fastest.speed {
      speedValue = String(format: "%.1f", speed)
      speedDetail = t("status.summary.tokPerSec", ["name": fastest.title ?? t("status.summary.fastestSample")])
    }

    var resetValue = t("status.summary.notReported")
    var resetDetail = t("status.summary.noResetTimestamp")
    if let nextReset {
      resetValue = resetCountdown(nextReset.timestamp, t)
      resetDetail = "\(nextReset.provider), \(nextReset.label)"
    }

    return [
      StatusSummaryEntry(
        label: t("status.summary.router"),
        value: routerValue,
        detail: routerDetail,
        tone: healthOK ? .success : .danger,
        pending: data.healthPending
      ),
      StatusSummaryEntry(
        label: t("status.summary.runningChats"),
        value: Format.exactNumber(Double(chatCount), t),
        detail: t("status.summary.uniqueActiveSessions"),
        pending: data.healthPending
      ),
      StatusSummaryEntry(
        label: t("status.summary.runningAgents"),
        value: Format.exactNumber(Double(runningAgentCount), t),
        detail: t("status.summary.namedSubagents"),
        pending: data.healthPending
      ),
      StatusSummaryEntry(
        label: t("status.summary.liveRequests"),
        value: Format.exactNumber(Double(data.activeRequestCount), t),
        detail: t("status.summary.concurrentWork"),
        pending: data.healthPending
      ),
      StatusSummaryEntry(
        label: t("status.summary.modelSpeed"),
        value: speedValue,
        detail: speedDetail,
        pending: data.providerUsagePending
      ),
      StatusSummaryEntry(
        label: t("status.summary.contextReused"),
        value: data.hasCacheTelemetry ? Format.compactNumber(data.cachedInputTokens, t) : t("status.summary.notReported"),
        detail: t("status.summary.cachedInputRecent24h"),
        pending: data.contextPending
      ),
      StatusSummaryEntry(
        label: t("status.summary.quotaReset"),
        value: resetValue,
        detail: resetDetail,
        pending: data.usagePending
      ),
    ]
  }
}
