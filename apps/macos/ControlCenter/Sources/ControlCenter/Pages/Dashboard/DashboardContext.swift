import ControlCenterCore
import Foundation

/// Which independently loaded sources have settled (`RouterDataReady`).
struct DashboardReadiness {
  var snapshot: Bool
  var health: Bool
  var accountUsage: Bool
  var providerUsage: Bool
}

/// Everything the Dashboard derives from the router's snapshots for one
/// render, computed once so each section reads the same numbers. Every input
/// can be missing on first paint and after a failed refresh, so each figure
/// separates three cases: still loading, reported-but-absent, and a genuine
/// zero. A missing field must never render as 0.
struct DashboardContext {
  let t: Translator
  let now: Double
  let refreshing: Bool

  let health: JSONValue?
  let account: JSONValue?
  let providerUsage: JSONValue?
  let target: JSONValue?
  let routeProviders: [JSONValue]

  let healthPending: Bool
  let snapshotPending: Bool
  let routesPending: Bool
  let providerUsagePending: Bool
  let quotaPending: Bool
  /// "Checking" while a refresh is running, otherwise "Unavailable".
  let pending: String

  let events: [DashboardEvent]?
  let eventHours: [JSONValue]?

  let activityMeasured: Bool
  let liveCount: Double?
  let chatCount: Int
  let subagentCount: Int
  let routerState: String

  let reportedTokens24h: Double?
  let rollupTokens24h: Double?
  let tokens24h: Double?
  let requests24h: Double?
  let usageMeasured: Bool

  let quotaLoaded: Bool
  let nextReset: DashboardNextReset?
  let lowestAllowance: DashboardLowestAllowance?
  let allowanceTone: Tone?

  let recentEvents: [DashboardEvent]
  let providerBreakdown: [DashboardBreakdownRow]
  let modelBreakdown: [DashboardBreakdownRow]

  init(
    t: Translator,
    now: Double,
    refreshing: Bool,
    ready: DashboardReadiness,
    health rawHealth: JSONValue?,
    account rawAccount: JSONValue?,
    providerUsage rawProviderUsage: JSONValue?,
    target rawTarget: JSONValue?,
    dashboard rawDashboard: JSONValue?
  ) {
    let health = DashboardJS.nullish(rawHealth)
    let account = DashboardJS.nullish(rawAccount)
    let providerUsage = DashboardJS.nullish(rawProviderUsage)
    let target = DashboardJS.nullish(rawTarget)
    let dashboard = DashboardJS.nullish(rawDashboard)

    let healthPending = !ready.health && health == nil
    let snapshotPending = !ready.snapshot && target == nil
    let routesPending = !ready.snapshot && dashboard == nil
    let accountPending = !ready.accountUsage && account == nil
    let providerUsagePending = !ready.providerUsage && providerUsage == nil
    let quotaPending = account == nil && providerUsage == nil && (accountPending || providerUsagePending)

    // Live activity.
    let activity = health?["activity"]
    let active = activity?["active"]?.items ?? []
    let activityMeasured = health != nil && activity.truthy
    var liveCount: Double?
    if activityMeasured {
      if let reported = DashboardJS.nullish(activity?["activeCount"]) {
        liveCount = DashboardJS.numberOrZero(reported)
      } else {
        liveCount = Double(active.count)
      }
    }
    var subagentCount = 0
    var sessionKeys = Set<String>()
    for (index, request) in active.enumerated() {
      // An older health payload may omit identifiers. Count those requests by
      // position instead of silently turning a busy router into "0 chats".
      let raw = DashboardJS.nullish(request["sessionId"])
        ?? DashboardJS.nullish(request["sessionName"])
        ?? DashboardJS.nullish(request["threadId"])
        ?? DashboardJS.nullish(request["id"])
      let key = DashboardContext.identity(raw)
      sessionKeys.insert(key.isEmpty ? "unknown-\(index)" : key)
      if request["isSubagent"]?.bool == true
        || request["agentName"].truthy
        || request["agentNickname"].truthy
      {
        subagentCount += 1
      }
    }
    let routerState = DashboardContext.state(health: health, activity: activity, refreshing: refreshing)

    // Rolling 24-hour traffic. Older installed routers expose the same bounded
    // event stream but predate the provider-level rolling counters; the hourly
    // rollup covers the whole window where the capped event sample understates
    // a busy day, so the order of preference is provider rows, rollup, events.
    var events: [DashboardEvent]?
    if let raw = target?["usageEvents"]?.array {
      events = raw.map { DashboardEvent($0) }
    }
    let eventHours = target?["usageEventHours"]?.array
    let telemetryEvents24h = DashboardStats.recentWindowEvents(events, now: now)
    let eventTokens24h = DashboardStats.sumEventTokens(telemetryEvents24h)
    let eventRequests24h: Double? = events == nil ? nil : Double(telemetryEvents24h.count)
    var rollupTokens24h: Double?
    if let hours = eventHours, hours.contains(where: { $0["measuredTokens"].truthy }) {
      rollupTokens24h = hours.reduce(0.0) { $0 + DashboardJS.numberOrZero($1["tokens"]) }
    }
    var rollupRequests24h: Double?
    if let hours = eventHours, !hours.isEmpty {
      rollupRequests24h = hours.reduce(0.0) { $0 + DashboardJS.numberOrZero($1["requests"]) }
    }
    let usageProviders = providerUsage?["providers"]?.items ?? []
    let reportedTokens24h = DashboardStats.sumReported(usageProviders.map { $0["last24hTokens"] })
    let reportedRequests24h = DashboardStats.sumReported(usageProviders.map { $0["last24hRequests"] })
    let tokens24h = reportedTokens24h ?? rollupTokens24h ?? eventTokens24h
    let requests24h = reportedRequests24h ?? rollupRequests24h ?? eventRequests24h
    let usageMeasured = providerUsage != nil || events != nil || !(eventHours ?? []).isEmpty

    // Quota.
    let metrics = DashboardStats.collectMetrics(t: t, account: account, providerUsage: providerUsage)
    let lowestAllowance = DashboardStats.lowestAllowance(metrics)
    var allowanceTone: Tone?
    if let lowest = lowestAllowance {
      if lowest.percent < 15 {
        allowanceTone = .danger
      } else if lowest.percent < 35 {
        allowanceTone = .warning
      }
    }

    var recentEvents: [DashboardEvent] = []
    if let all = events {
      recentEvents = Array(all.reversed().prefix(DashboardStats.recentEventLimit))
    }

    self.t = t
    self.now = now
    self.refreshing = refreshing
    self.health = health
    self.account = account
    self.providerUsage = providerUsage
    self.target = target
    self.routeProviders = dashboard?["providers"]?.items ?? []
    self.healthPending = healthPending
    self.snapshotPending = snapshotPending
    self.routesPending = routesPending
    self.providerUsagePending = providerUsagePending
    self.quotaPending = quotaPending
    self.pending = refreshing ? t("status.summary.checking") : t("status.summary.unavailable")
    self.events = events
    self.eventHours = eventHours
    self.activityMeasured = activityMeasured
    self.liveCount = liveCount
    self.chatCount = sessionKeys.count
    self.subagentCount = subagentCount
    self.routerState = routerState
    self.reportedTokens24h = reportedTokens24h
    self.rollupTokens24h = rollupTokens24h
    self.tokens24h = tokens24h
    self.requests24h = requests24h
    self.usageMeasured = usageMeasured
    self.quotaLoaded = account != nil || providerUsage != nil
    self.nextReset = DashboardStats.nextReset(metrics, now: now)
    self.lowestAllowance = lowestAllowance
    self.allowanceTone = allowanceTone
    self.recentEvents = recentEvents
    self.providerBreakdown = DashboardStats.buildProviderBreakdown(providerUsage: providerUsage, events: events, now: now)
    self.modelBreakdown = DashboardStats.buildModelBreakdown(providerUsage: providerUsage, events: events, now: now)
  }

  /// The health error worth an inline notice: the router answered, said it is
  /// not ok, and gave a reason.
  var healthErrorMessage: String? {
    guard let health = health, !health["ok"].truthy else { return nil }
    return DashboardJS.nonEmpty(health["error"])
  }

  /// `[identifier] || "unknown-<n>"`: empty, zero, and false identifiers count
  /// as absent.
  private static func identity(_ value: JSONValue?) -> String {
    guard let value = value else { return "" }
    switch value {
    case .string(let text): return text
    case .number(let number): return number == 0 || number.isNaN ? "" : DashboardJS.string(number)
    case .bool(let flag): return flag ? "true" : ""
    case .array, .object: return "object"
    case .null: return ""
    }
  }

  private static func state(health: JSONValue?, activity: JSONValue?, refreshing: Bool) -> String {
    guard let health = health else { return refreshing ? "starting" : "offline" }
    if !health["ok"].truthy { return "offline" }
    return DashboardJS.nonEmpty(activity?["state"]) ?? "idle"
  }
}
