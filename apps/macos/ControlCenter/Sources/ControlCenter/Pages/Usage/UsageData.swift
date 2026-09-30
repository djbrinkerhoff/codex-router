import ControlCenterCore
import Foundation

// The Usage page's data model, ported from the pure functions in
// `UsagePage.tsx`. Everything here is a plain value computation over the
// router's JSON so the view code stays declarative.

enum UsageSourceKind { case aggregate, subscription, provider }

/// Where one displayed day came from. `routerFallback` is a day the ChatGPT
/// account stream lacks and the router's own OpenAI meter fills in.
enum UsageOrigin { case account, routerFallback }

enum UsageTokenTone { case total, regular, cached, output }

enum UsagePartTone { case regularInput, cachedInput, output, other }

struct UsageTokenPart {
  let tone: UsagePartTone
  let label: String
  let tokens: Double
}

/// One selectable usage stream: the router aggregate, the ChatGPT account, or
/// one provider. Counters are optional because an absent field is not zero.
struct UsageSourceEntry: Identifiable {
  let id: String
  var kind: UsageSourceKind
  var name: String
  var detail: String
  /// Bucket objects as the router wrote them (subscription buckets also carry
  /// a synthetic `displaySource`).
  var buckets: [JSONValue]
  var metrics: [JSONValue]
  var enabled: Bool

  var requests: Double?
  var successfulRequests: Double?
  var meteredRequests: Double?
  var inputTokens: Double?
  var regularInputTokens: Double?
  var cachedInputTokens: Double?
  /// Older backends do not say whether a provider ever reported cache
  /// telemetry; `nil` keeps that unknown apart from a known-absent `false`.
  var cacheTelemetrySeen: Bool?
  var outputTokens: Double?
  var totalTokens: Double?
  var last24hInputTokens: Double?
  var last24hRegularInputTokens: Double?
  var last24hCachedInputTokens: Double?
  var last24hOutputTokens: Double?
  var last24hTokens: Double?
  var last24hRequests: Double?
  var last24hMeteredRequests: Double?
  var accountStatus: String?
  var message: String?
  var dashboardUrl: String?
  var plan: String?
  var lifetimeTokens: Double?
  var peakDailyTokens: Double?
  var streakDays: Double?
  var scopeLabel: String?
  var windowStart: String?
}

/// One day of a chart range, after gaps are filled.
struct UsageDayBucket: Identifiable {
  var id: String { startDate }
  var startDate: String
  var tokens: Double
  var requests: Double?
  var inputTokens: Double?
  var cachedInputTokens: Double?
  var outputTokens: Double?
  var origin: UsageOrigin?
}

struct UsageSummaryEntry: Identifiable {
  var id: String { label }
  let label: String
  let value: String
  let detail: String
  var tone: UsageTokenTone?
}

struct UsageAllowanceEntry: Identifiable {
  let id: String
  let sourceID: String
  let sourceName: String
  let metric: JSONValue
}

struct UsageEventTotals {
  var requests: Double
  var meteredRequests: Double
  var inputTokens: Double?
  var regularInputTokens: Double?
  var cachedInputTokens: Double?
  var outputTokens: Double?
  var tokens: Double?
}

struct UsageChartSegment: Identifiable {
  let startDate: String
  /// "regular", "cached", "output", "other" or "total".
  let series: String
  let tokens: Double
  let fallback: Bool
  var id: String { "\(startDate)|\(series)" }
}

struct UsageMixRow: Identifiable {
  var id: String { label }
  let label: String
  let value: Double?
  let tone: UsageTokenTone
}

/// The cache key for one computation of the page's sources. The window polls
/// health every second, so the heavy work is skipped while nothing it reads
/// has changed.
private struct UsageSourceKey: Equatable {
  var language: String
  var minute: Int
  var enabledProviders: [String]
  var usageEvents: [JSONValue]?
  var account: JSONValue?
  var providerUsage: JSONValue?
}

/// Memoizes `UsageLogic.buildSources` and the per-range buckets. A reference
/// type held in `@State`, so filling it during `body` does not invalidate the
/// view.
final class UsageComputationCache {
  private var key: UsageSourceKey?
  private var cachedSources: [UsageSourceEntry] = []
  private var rangeBuckets: [String: [UsageDayBucket]] = [:]

  func sources(t: Translator, target: JSONValue?, account: JSONValue?, providerUsage: JSONValue?) -> [UsageSourceEntry] {
    let next = UsageSourceKey(
      language: t.language,
      minute: Int(Date().timeIntervalSince1970 / 60),
      enabledProviders: target?["enabledProviders"]?.strings ?? [],
      usageEvents: target?["usageEvents"]?.array,
      account: account,
      providerUsage: providerUsage
    )
    if key == next { return cachedSources }
    key = next
    rangeBuckets = [:]
    cachedSources = UsageLogic.buildSources(t, target: target, account: account, snapshot: providerUsage)
    return cachedSources
  }

  func buckets(for source: UsageSourceEntry, days: Int) -> [UsageDayBucket] {
    let cacheKey = "\(source.id)|\(days)"
    if let existing = rangeBuckets[cacheKey] { return existing }
    let computed = UsageLogic.bucketsForRange(source.buckets, days: days)
    rangeBuckets[cacheKey] = computed
    return computed
  }
}

enum UsageLogic {
  /// The status snapshot keeps a bounded 90-day view for fast rolling counters
  /// and also exposes the complete retained append-only ledger.
  static let ledgerDays = 90

  // MARK: Small helpers

  static func present(_ value: JSONValue?) -> Bool {
    guard let value else { return false }
    return !value.isNull
  }

  /// A JavaScript `||` over strings: the first non-empty value.
  static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static func sumNullable(_ values: [Double?]) -> Double? {
    if values.isEmpty { return nil }
    var total = 0.0
    for value in values {
      guard let value else { return nil }
      total += value
    }
    return total
  }

  static func optionalCompact(_ value: Double?, _ t: Translator) -> String {
    guard let value else { return t("usage.summary.notReported") }
    return Format.compactNumber(value, t)
  }

  /// A rate needs both halves reported: a route that meters cached tokens but
  /// never reports prompt totals has no ratio, and "0%" would be
  /// indistinguishable from a real cold cache.
  static func cacheHitRatePercent(cached: Double?, input: Double?) -> Double? {
    guard let cached, let input, cached.isFinite, input.isFinite, input > 0 else { return nil }
    return min(100, max(0, cached / input * 100))
  }

  static func formatPercent(_ value: Double) -> String {
    String(format: "%.\(value > 0 && value < 10 ? 1 : 0)f", value) + "%"
  }

  static func friendlyPlanName(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
    var result = ""
    var previousIsWord = false
    for character in spaced {
      let isWord = character.isLetter || character.isNumber || character == "_"
      if isWord && !previousIsWord {
        result += String(character).uppercased()
      } else {
        result.append(character)
      }
      previousIsWord = isWord
    }
    return result
  }

  static func formatBucketDate(_ value: String?, _ t: Translator) -> String {
    guard let value, !value.isEmpty else { return t("display.noData") }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone.current
    parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    guard let date = parser.date(from: value + "T12:00:00") else { return value }
    let formatter = DateFormatter()
    formatter.locale = t.locale
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: date)
  }

  /// A quota reset as a finite number of seconds or milliseconds since the
  /// epoch (`metric.resetAt ?? metric.resetsAt`).
  static func metricResetAt(_ metric: JSONValue) -> Double? {
    metric["resetAt"]?.double ?? metric["resetsAt"]?.double
  }

  static func resetCountdown(_ value: Double, _ t: Translator, now: Date = Date()) -> String {
    let timestamp = value < 10_000_000_000 ? value * 1_000 : value
    guard timestamp.isFinite else { return t("usage.countdown.unavailable") }
    let remaining = timestamp - now.timeIntervalSince1970 * 1_000
    if remaining <= 0 { return t("usage.countdown.refreshDue") }
    let minutes = Int((remaining / 60_000).rounded(.up))
    if minutes < 60 { return t("usage.countdown.minutes", ["minutes": minutes]) }
    let hours = minutes / 60
    if hours < 24 { return t("usage.countdown.hours", ["hours": hours, "minutes": minutes % 60]) }
    let days = hours / 24
    return t("usage.countdown.days", ["days": days, "hours": hours % 24])
  }

  static func hasMetricCounts(_ metric: JSONValue) -> Bool {
    metric["used"]?.double != nil || metric["remaining"]?.double != nil || metric["limit"]?.double != nil
  }

  static func formatMetricCount(_ value: Double?, unit: String?, _ t: Translator) -> String {
    guard let value else { return t("usage.summary.notReported") }
    let formatted = Format.exactNumber(value, t)
    if let unit, !unit.isEmpty { return "\(formatted) \(unit)" }
    return formatted
  }

  static func navigationSourceID(_ sourceID: String?) -> String? {
    guard let sourceID, !sourceID.isEmpty else { return nil }
    // The menu-bar/widget Codex source is the account-reported stream used
    // for its graph and reset windows, not the separate traffic ledger.
    return sourceID == "openai" ? "chatgpt-subscription" : "provider:\(sourceID)"
  }

  static func limitWindowLabel(_ minutes: Double?, index: Int, _ t: Translator) -> String {
    guard let value = minutes else {
      return index == 0 ? t("status.limit.primary") : t("status.limit.secondary")
    }
    if value >= 1_440, value.truncatingRemainder(dividingBy: 1_440) == 0 {
      let days = Int(value / 1_440)
      if days == 1 { return t("status.limit.daily") }
      if days == 7 { return t("status.limit.weekly") }
      return t("status.limit.days", ["days": days])
    }
    if value >= 60, value.truncatingRemainder(dividingBy: 60) == 0 {
      return t("status.limit.hours", ["hours": Int(value / 60)])
    }
    let text = value == value.rounded() ? String(Int(value)) : String(value)
    return t("status.limit.minutes", ["minutes": text])
  }

  static func codexAccountMetrics(_ account: JSONValue, _ t: Translator) -> [JSONValue] {
    var metrics: [JSONValue] = []
    let windows: [JSONValue?] = [account["primary"], account["secondary"]]
    for (index, window) in windows.enumerated() {
      guard let window, let base = window.object else { continue }
      var metric = base
      metric["kind"] = .string("quota")
      metric["label"] = .string(limitWindowLabel(window["windowDurationMins"]?.double, index: index, t))
      if let plan = account["planType"]?.text {
        metric["detail"] = .string(t("usage.metric.plan", ["plan": friendlyPlanName(plan)]))
      } else {
        metric["detail"] = .string(t("usage.metric.chatgptLimit"))
      }
      metrics.append(.object(metric))
    }
    return metrics
  }

  // MARK: Rolling event totals

  private static func eventNumber(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value.rounded()
  }

  /// Older installed routers expose the bounded event stream but not the newer
  /// provider-level rolling counters. Keep the aggregate useful during that
  /// version skew.
  static func rollingEventTotals(_ events: [JSONValue]?, now: Date = Date()) -> UsageEventTotals? {
    guard let events else { return nil }
    let cutoff = now.addingTimeInterval(-24 * 60 * 60)
    var requests = 0.0
    var meteredRequests = 0.0
    var measured = false
    var cacheTelemetry = false
    var inputTokens = 0.0
    var regularInputTokens = 0.0
    var cachedInputTokens = 0.0
    var outputTokens = 0.0
    var tokens = 0.0
    for event in events {
      guard let text = event["at"]?.string, let at = Format.date(.string(text)) else { continue }
      if at < cutoff || at > now { continue }
      requests += 1
      let input = eventNumber(event["billedInputTokens"]?.double ?? event["inputTokens"]?.double)
      let output = eventNumber(event["billedOutputTokens"]?.double ?? event["outputTokens"]?.double)
      let explicitTotal = eventNumber(event["totalTokens"]?.double)
      if input == nil && output == nil && explicitTotal == nil { continue }
      meteredRequests += 1
      measured = true
      let inputValue = input ?? 0
      let cached = eventNumber(event["cachedInputTokens"]?.double)
      let cachedValue: Double
      if let cached {
        cachedValue = input == nil ? cached : min(inputValue, cached)
      } else {
        cachedValue = 0
      }
      inputTokens += inputValue
      regularInputTokens += max(0, inputValue - cachedValue)
      cachedInputTokens += cachedValue
      outputTokens += output ?? 0
      tokens += explicitTotal ?? (inputValue + (output ?? 0))
      if cached != nil { cacheTelemetry = true }
    }
    return UsageEventTotals(
      requests: requests,
      meteredRequests: meteredRequests,
      inputTokens: measured ? inputTokens : nil,
      regularInputTokens: measured ? regularInputTokens : nil,
      cachedInputTokens: (measured && cacheTelemetry) ? cachedInputTokens : nil,
      outputTokens: measured ? outputTokens : nil,
      tokens: measured ? tokens : nil
    )
  }

  // MARK: Buckets

  private struct BucketAccumulator {
    var tokens = 0.0
    var requests = 0.0
    var input: Double?
    var cached: Double?
    var output: Double?
  }

  static func mergeBuckets(_ groups: [[JSONValue]]) -> [JSONValue] {
    var merged: [String: BucketAccumulator] = [:]
    for group in groups {
      for bucket in group {
        guard let key = bucket["startDate"]?.string else { continue }
        var entry = merged[key] ?? BucketAccumulator()
        entry.tokens += bucket["tokens"]?.double ?? 0
        entry.requests += bucket["requests"]?.double ?? 0
        if present(bucket["inputTokens"]) { entry.input = (entry.input ?? 0) + (bucket["inputTokens"]?.double ?? 0) }
        if present(bucket["cachedInputTokens"]) { entry.cached = (entry.cached ?? 0) + (bucket["cachedInputTokens"]?.double ?? 0) }
        if present(bucket["outputTokens"]) { entry.output = (entry.output ?? 0) + (bucket["outputTokens"]?.double ?? 0) }
        merged[key] = entry
      }
    }
    var result: [JSONValue] = []
    for key in merged.keys.sorted() {
      guard let entry = merged[key] else { continue }
      var object: [String: JSONValue] = [
        "startDate": .string(key),
        "tokens": .number(entry.tokens),
        "requests": .number(entry.requests),
      ]
      if let input = entry.input { object["inputTokens"] = .number(input) }
      if let cached = entry.cached { object["cachedInputTokens"] = .number(cached) }
      if let output = entry.output { object["outputTokens"] = .number(output) }
      result.append(.object(object))
    }
    return result
  }

  static func originOf(_ source: JSONValue) -> UsageOrigin? {
    switch source["displaySource"]?.string {
    case "router-fallback": return .routerFallback
    case "account": return .account
    default: return nil
    }
  }

  /// The last `days` UTC days with gaps filled, carrying request counts only
  /// where the TSX does.
  static func bucketsForRange(_ buckets: [JSONValue], days: Int) -> [UsageDayBucket] {
    let dates = Format.bucketRange(buckets, days: days)
    var requestsByDate: [String: Double] = [:]
    var hasRequestData = false
    var hasDisplaySources = false
    for bucket in buckets {
      if let key = bucket["startDate"]?.string {
        requestsByDate[key] = bucket["requests"]?.double ?? 0
      }
      if present(bucket["requests"]) { hasRequestData = true }
      if bucket["displaySource"]?.string != nil { hasDisplaySources = true }
    }
    var result: [UsageDayBucket] = []
    for date in dates {
      let origin = originOf(date.source)
      var requests: Double? = date.source["requests"]?.double
      if hasRequestData && (!hasDisplaySources || origin == .routerFallback) {
        requests = requestsByDate[date.startDate] ?? 0
      }
      result.append(UsageDayBucket(
        startDate: date.startDate,
        tokens: date.tokens,
        requests: requests,
        inputTokens: date.source["inputTokens"]?.double,
        cachedInputTokens: date.source["cachedInputTokens"]?.double,
        outputTokens: date.source["outputTokens"]?.double,
        origin: origin
      ))
    }
    return result
  }

  static func tokenParts(_ bucket: UsageDayBucket, _ t: Translator) -> [UsageTokenPart]? {
    guard bucket.inputTokens != nil || bucket.cachedInputTokens != nil || bucket.outputTokens != nil else { return nil }
    let inputReported = bucket.inputTokens != nil
    let input = max(0, bucket.inputTokens ?? 0)
    let rawCached = max(0, bucket.cachedInputTokens ?? 0)
    let cached = inputReported ? min(input, rawCached) : min(bucket.tokens, rawCached)
    let regular = max(0, input - cached)
    let output = max(0, bucket.outputTokens ?? 0)
    let other = max(0, bucket.tokens - regular - cached - output)
    return [
      UsageTokenPart(tone: .regularInput, label: t("usage.token.regularInput"), tokens: regular),
      UsageTokenPart(tone: .cachedInput, label: t("usage.token.cachedInput"), tokens: cached),
      UsageTokenPart(tone: .output, label: t("usage.token.output"), tokens: output),
      UsageTokenPart(tone: .other, label: t("usage.token.other"), tokens: other),
    ]
  }

  /// A range-level mix can claim the selected scope only when every day
  /// carrying tokens has a split.
  static func hasCompleteTokenBreakdown(_ buckets: [UsageDayBucket], _ t: Translator) -> Bool {
    let tokenBuckets = buckets.filter { $0.tokens > 0 }
    if tokenBuckets.isEmpty { return false }
    return tokenBuckets.allSatisfy { tokenParts($0, t) != nil }
  }

  static func hasFallbackDays(_ buckets: [UsageDayBucket]) -> Bool {
    buckets.contains { $0.origin == .routerFallback }
  }

  static func chartSegments(_ buckets: [UsageDayBucket], breakdownAvailable: Bool, _ t: Translator) -> [UsageChartSegment] {
    var segments: [UsageChartSegment] = []
    for bucket in buckets {
      let fallback = bucket.origin == .routerFallback
      let parts = breakdownAvailable ? tokenParts(bucket, t) : nil
      guard let parts else {
        if bucket.tokens > 0 {
          segments.append(UsageChartSegment(startDate: bucket.startDate, series: "total", tokens: bucket.tokens, fallback: fallback))
        }
        continue
      }
      for part in parts where part.tokens > 0 {
        segments.append(UsageChartSegment(
          startDate: bucket.startDate,
          series: seriesName(part.tone),
          tokens: part.tokens,
          fallback: fallback
        ))
      }
    }
    return segments
  }

  static func seriesName(_ tone: UsagePartTone) -> String {
    switch tone {
    case .regularInput: return "regular"
    case .cachedInput: return "cached"
    case .output: return "output"
    case .other: return "other"
    }
  }

  // MARK: Token mix

  static func tokenMix(source: UsageSourceEntry, buckets: [UsageDayBucket], range: Int, _ t: Translator) -> (rows: [UsageMixRow], scope: String)? {
    let complete = hasCompleteTokenBreakdown(buckets, t)
      && (source.kind != .subscription || !hasFallbackDays(buckets))
    var mixRegular = 0.0
    var mixCached = 0.0
    var mixOutput = 0.0
    for bucket in buckets {
      guard let parts = tokenParts(bucket, t) else { continue }
      for part in parts {
        switch part.tone {
        case .regularInput: mixRegular += part.tokens
        case .cachedInput: mixCached += part.tokens
        case .output: mixOutput += part.tokens
        case .other: break
        }
      }
    }
    let isSubscription = source.kind == .subscription
    let input: Double? = isSubscription ? nil : source.last24hInputTokens
    var recentRegular: Double?
    if !isSubscription {
      if let value = source.last24hRegularInputTokens {
        recentRegular = value
      } else if let input, let cached = source.last24hCachedInputTokens {
        recentRegular = max(0, input - cached)
      }
    }
    let recentCached: Double? = isSubscription ? nil : source.last24hCachedInputTokens
    let recentOutput: Double? = isSubscription ? nil : source.last24hOutputTokens
    let regular: Double? = complete ? mixRegular : recentRegular
    let cached: Double? = complete ? mixCached : recentCached
    let output: Double? = complete ? mixOutput : recentOutput
    if regular == nil && cached == nil && output == nil { return nil }
    let scope = complete ? t("usage.scope.selectedRange", ["range": range]) : t("usage.scope.last24h")
    let rows = [
      UsageMixRow(label: t("usage.summary.regularInput"), value: regular, tone: .regular),
      UsageMixRow(label: t("usage.summary.cachedInput"), value: cached, tone: .cached),
      UsageMixRow(label: t("usage.summary.output"), value: output, tone: .output),
    ]
    return (rows, scope)
  }

  // MARK: Sources

  static func buildSources(_ t: Translator, target: JSONValue?, account: JSONValue?, snapshot: JSONValue?) -> [UsageSourceEntry] {
    let enabled = Set(target?["enabledProviders"]?.strings ?? [])
    let eventFallback = rollingEventTotals(target?["usageEvents"]?.array)
    var providerSources: [UsageSourceEntry] = []
    let currentProviders = snapshot?["providers"]?.items ?? []
    let retainedProviders = snapshot?["retained"]?["providers"]?.items ?? []
    var currentByID: [String: JSONValue] = [:]
    var retainedByID: [String: JSONValue] = [:]
    var providerIDs: [String] = []
    for provider in currentProviders {
      guard let id = provider["id"]?.string else { continue }
      currentByID[id] = provider
      if !providerIDs.contains(id) { providerIDs.append(id) }
    }
    for provider in retainedProviders {
      guard let id = provider["id"]?.string else { continue }
      retainedByID[id] = provider
      if !providerIDs.contains(id) { providerIDs.append(id) }
    }
    let retainedFromValue: JSONValue? = snapshot?["retained"]?["from"]
    let hasRetainedLedger = retainedFromValue.truthy
    let retainedScopeLabel = hasRetainedLedger
      ? t("usage.scope.allRetained")
      : t("usage.scope.lastDays", ["days": ledgerDays])
    let retainedFrom = retainedFromValue?.string

    for providerID in providerIDs {
      // Lead with all retained events when the backend provides them, while
      // borrowing account metadata and rolling counters from the bounded
      // snapshot.
      let recentProvider = currentByID[providerID]
      guard let provider = retainedByID[providerID] ?? recentProvider else { continue }
      let providerAccount: JSONValue? = recentProvider?["account"]
      let metrics = providerAccount?["metrics"]?.items ?? []
      let hasTraffic = hasTrafficIn(provider) || hasTrafficIn(recentProvider)
      let hasAccount = !metrics.isEmpty || providerAccount?["status"]?.string == "available"
      if !enabled.contains(providerID) && providerID != "openai" && !hasTraffic && !hasAccount { continue }

      // The provider:openai row and the chatgpt-subscription row are two
      // meters over one quota pool, not a double count. Naming the meter is
      // what keeps an operator from reading one subscription as two.
      let displayName = provider["displayName"]?.string ?? providerID
      let providerName = providerID == "openai" ? t("usage.source.chatgptMeasured") : displayName
      let detail: String
      if providerID == "openai" {
        let scope = hasRetainedLedger
          ? t("usage.scope.allRetained")
          : t("usage.scope.days", ["days": ledgerDays])
        detail = t("usage.source.openaiDetail", ["scope": scope])
      } else {
        let credential = nonEmpty(provider["credentialType"]?.string?.uppercased()) ?? t("usage.source.providerFallback")
        detail = t("usage.source.providerTraffic", [
          "credential": credential,
          "scope": hasRetainedLedger ? t("usage.source.retainedSuffix") : "",
        ])
      }
      var entry = UsageSourceEntry(
        id: "provider:\(providerID)",
        kind: .provider,
        name: providerName,
        detail: detail,
        buckets: provider["dailyUsageBuckets"]?.items ?? [],
        metrics: metrics,
        enabled: providerID == "openai" || enabled.contains(providerID)
      )
      // Never coerce an absent field to zero: "0 tokens" is indistinguishable
      // from genuinely idle.
      entry.requests = provider["requests"]?.double
      entry.successfulRequests = provider["successfulRequests"]?.double
      entry.meteredRequests = provider["meteredRequests"]?.double
      entry.inputTokens = provider["inputTokens"]?.double
      entry.regularInputTokens = provider["regularInputTokens"]?.double
      entry.cachedInputTokens = provider["cachedInputTokens"]?.double
      entry.cacheTelemetrySeen = provider["cacheTelemetrySeen"]?.bool
      entry.outputTokens = provider["outputTokens"]?.double
      entry.totalTokens = provider["totalTokens"]?.double
      entry.last24hInputTokens = recentProvider?["last24hInputTokens"]?.double ?? provider["last24hInputTokens"]?.double
      entry.last24hRegularInputTokens = recentProvider?["last24hRegularInputTokens"]?.double ?? provider["last24hRegularInputTokens"]?.double
      entry.last24hCachedInputTokens = recentProvider?["last24hCachedInputTokens"]?.double ?? provider["last24hCachedInputTokens"]?.double
      entry.last24hOutputTokens = recentProvider?["last24hOutputTokens"]?.double ?? provider["last24hOutputTokens"]?.double
      entry.last24hTokens = recentProvider?["last24hTokens"]?.double ?? provider["last24hTokens"]?.double
      entry.last24hRequests = recentProvider?["last24hRequests"]?.double ?? provider["last24hRequests"]?.double
      entry.last24hMeteredRequests = recentProvider?["last24hMeteredRequests"]?.double ?? provider["last24hMeteredRequests"]?.double
      entry.accountStatus = providerAccount?["status"]?.string
      entry.message = providerAccount?["message"]?.string
      entry.dashboardUrl = providerAccount?["dashboardUrl"]?.string
      entry.plan = providerAccount?["plan"]?.string
      entry.scopeLabel = retainedScopeLabel
      entry.windowStart = retainedFrom
      providerSources.append(entry)
    }

    var result: [UsageSourceEntry] = []
    if snapshot?.object != nil {
      result.append(aggregateSource(t, providerSources: providerSources, eventFallback: eventFallback, scopeLabel: retainedScopeLabel, windowStart: retainedFrom))
    }
    if let account {
      result.append(subscriptionSource(t, account: account, providerSources: providerSources))
    }
    // Keep the two ChatGPT meters next to each other so one subscription seen
    // twice never reads as two unrelated accounts.
    result.append(contentsOf: providerSources.filter { $0.id == "provider:openai" })
    result.append(contentsOf: providerSources.filter { $0.id != "provider:openai" })
    return result
  }

  private static func hasTrafficIn(_ entry: JSONValue?) -> Bool {
    guard let entry else { return false }
    func positive(_ key: String) -> Bool { (entry[key]?.double ?? 0) > 0 }
    if positive("requests") || positive("totalTokens") || positive("inputTokens") || positive("outputTokens")
      || positive("last24hRequests") || positive("last24hTokens")
    {
      return true
    }
    let hasBucketTraffic = (entry["dailyUsageBuckets"]?.items ?? []).contains { bucket in
      (bucket["tokens"]?.double ?? 0) > 0 || (bucket["requests"]?.double ?? 0) > 0
    }
    if hasBucketTraffic { return true }
    return (entry["models"]?.items ?? []).contains { ($0["requests"]?.double ?? 0) > 0 }
  }

  private static func aggregateSource(
    _ t: Translator,
    providerSources: [UsageSourceEntry],
    eventFallback: UsageEventTotals?,
    scopeLabel: String,
    windowStart: String?
  ) -> UsageSourceEntry {
    let reportedLast24Tokens = sumNullable(providerSources.map { $0.last24hTokens })
    let rollingSuffix = (reportedLast24Tokens == nil && eventFallback?.tokens != nil)
      ? t("usage.source.aggregateRollingSuffix")
      : ""
    var entry = UsageSourceEntry(
      id: "all-router",
      kind: .aggregate,
      name: t("usage.source.allProviders"),
      detail: t("usage.source.aggregateDetail") + rollingSuffix,
      buckets: mergeBuckets(providerSources.map { $0.buckets }),
      metrics: [],
      enabled: true
    )
    entry.requests = sumNullable(providerSources.map { $0.requests })
    entry.successfulRequests = sumNullable(providerSources.map { $0.successfulRequests })
    entry.meteredRequests = sumNullable(providerSources.map { $0.meteredRequests })
    entry.inputTokens = sumNullable(providerSources.map { $0.inputTokens })
    entry.regularInputTokens = sumNullable(providerSources.map { $0.regularInputTokens })
    entry.cachedInputTokens = sumNullable(providerSources.map { $0.cachedInputTokens })
    if providerSources.contains(where: { $0.cacheTelemetrySeen == true }) {
      entry.cacheTelemetrySeen = true
    } else if providerSources.allSatisfy({ $0.cacheTelemetrySeen == false }) {
      entry.cacheTelemetrySeen = false
    } else {
      entry.cacheTelemetrySeen = nil
    }
    entry.outputTokens = sumNullable(providerSources.map { $0.outputTokens })
    entry.totalTokens = sumNullable(providerSources.map { $0.totalTokens })
    entry.last24hInputTokens = sumNullable(providerSources.map { $0.last24hInputTokens }) ?? eventFallback?.inputTokens
    entry.last24hRegularInputTokens = sumNullable(providerSources.map { $0.last24hRegularInputTokens }) ?? eventFallback?.regularInputTokens
    entry.last24hCachedInputTokens = sumNullable(providerSources.map { $0.last24hCachedInputTokens }) ?? eventFallback?.cachedInputTokens
    entry.last24hOutputTokens = sumNullable(providerSources.map { $0.last24hOutputTokens }) ?? eventFallback?.outputTokens
    entry.last24hTokens = reportedLast24Tokens ?? eventFallback?.tokens
    entry.last24hRequests = sumNullable(providerSources.map { $0.last24hRequests }) ?? eventFallback?.requests
    entry.last24hMeteredRequests = sumNullable(providerSources.map { $0.last24hMeteredRequests }) ?? eventFallback?.meteredRequests
    entry.accountStatus = "local-router"
    entry.scopeLabel = scopeLabel
    entry.windowStart = windowStart
    return entry
  }

  private static func subscriptionSource(_ t: Translator, account: JSONValue, providerSources: [UsageSourceEntry]) -> UsageSourceEntry {
    let localOpenAiBuckets = providerSources.first { $0.id == "provider:openai" }?.buckets ?? []
    let merged = Format.accountBucketsWithRouterFallback(
      account: account["dailyUsageBuckets"]?.items ?? [],
      router: localOpenAiBuckets
    )
    var bucketObjects: [JSONValue] = []
    for bucket in merged {
      var object = bucket.source.object ?? [:]
      object["startDate"] = .string(bucket.startDate)
      object["tokens"] = .number(bucket.tokens)
      object["displaySource"] = .string(bucket.fromRouterFallback ? "router-fallback" : "account")
      bucketObjects.append(.object(object))
    }
    let fallbackDays = merged.filter { $0.fromRouterFallback }.count
    let planType = nonEmpty(account["planType"]?.string)
    let fallbackDetailKey = fallbackDays == 1 ? "usage.fallback.detailOne" : "usage.fallback.detail"

    let name = fallbackDays > 0 ? t("usage.fallback.source") : t("usage.source.chatgptReported")
    let detail: String
    if let planType {
      if fallbackDays > 0 {
        detail = "\(friendlyPlanName(planType)) plan · \(t(fallbackDetailKey, ["count": fallbackDays]))"
      } else {
        detail = t("usage.source.planDetail", ["plan": friendlyPlanName(planType)])
      }
    } else if fallbackDays > 0 {
      detail = t(fallbackDetailKey, ["count": fallbackDays])
    } else {
      detail = t("usage.source.accountDetail")
    }
    var entry = UsageSourceEntry(
      id: "chatgpt-subscription",
      kind: .subscription,
      name: name,
      detail: detail,
      buckets: bucketObjects,
      metrics: codexAccountMetrics(account, t),
      enabled: true
    )
    entry.totalTokens = account["summary"]?["lifetimeTokens"]?.double
    entry.accountStatus = "available"
    entry.plan = planType
    entry.lifetimeTokens = account["summary"]?["lifetimeTokens"]?.double
    entry.peakDailyTokens = account["summary"]?["peakDailyTokens"]?.double
    entry.streakDays = account["summary"]?["currentStreakDays"]?.double
    return entry
  }

  // MARK: Summary

  static func usageSummary(
    source: UsageSourceEntry,
    range: Int,
    rangeBuckets: [UsageDayBucket],
    rangeRequests: Double?,
    latestReportedBucket: JSONValue?,
    _ t: Translator
  ) -> [UsageSummaryEntry] {
    let rangeTokens = rangeBuckets.reduce(0.0) { $0 + $1.tokens }
    if source.kind == .subscription {
      return subscriptionSummary(source: source, range: range, rangeBuckets: rangeBuckets, rangeTokens: rangeTokens, latestReportedBucket: latestReportedBucket, t)
    }
    return routerSummary(source: source, range: range, rangeTokens: rangeTokens, rangeRequests: rangeRequests, t)
  }

  private static func subscriptionSummary(
    source: UsageSourceEntry,
    range: Int,
    rangeBuckets: [UsageDayBucket],
    rangeTokens: Double,
    latestReportedBucket: JSONValue?,
    _ t: Translator
  ) -> [UsageSummaryEntry] {
    let latestTokens = latestReportedBucket?["tokens"]?.double
    let fallbackBuckets = rangeBuckets.filter { $0.origin == .routerFallback }
    let fallbackTokens = fallbackBuckets.reduce(0.0) { $0 + $1.tokens }
    let fallbackDays = fallbackBuckets.count
    let accountTokens = rangeTokens - fallbackTokens

    var lastDayValue = t("usage.summary.notReported")
    if let latestTokens { lastDayValue = Format.compactNumber(latestTokens, t) }
    var lastDayDetail = t("usage.summary.noDailyBucket")
    if let latestReportedBucket {
      lastDayDetail = t("usage.summary.accountTokensDate", [
        "count": Format.exactNumber(latestTokens, t),
        "date": formatBucketDate(latestReportedBucket["startDate"]?.string, t),
      ])
    }
    let rangeDetail: String
    if fallbackDays > 0 {
      rangeDetail = t("usage.fallback.summary", [
        "total": Format.exactNumber(rangeTokens, t),
        "account": Format.exactNumber(accountTokens, t),
        "fallback": Format.exactNumber(fallbackTokens, t),
      ])
    } else {
      rangeDetail = t("usage.summary.accountTokens", ["count": Format.exactNumber(rangeTokens, t)])
    }
    let streakValue: String
    if let streak = source.streakDays {
      streakValue = t("usage.summary.streakDays", ["days": Int(streak.rounded())])
    } else {
      streakValue = t("usage.summary.notReported")
    }
    let planValue = nonEmpty(source.plan).map(friendlyPlanName) ?? t("usage.summary.notReported")
    return [
      UsageSummaryEntry(label: t("usage.summary.lastReportedDay"), value: lastDayValue, detail: lastDayDetail),
      UsageSummaryEntry(label: t("usage.summary.lastRangeDays", ["range": range]), value: Format.compactNumber(rangeTokens, t), detail: rangeDetail),
      UsageSummaryEntry(label: t("usage.summary.accountLifetime"), value: optionalCompact(source.lifetimeTokens, t), detail: t("usage.summary.reportedByOpenai")),
      UsageSummaryEntry(label: t("usage.summary.peakDay"), value: optionalCompact(source.peakDailyTokens, t), detail: t("usage.summary.accountHistory")),
      UsageSummaryEntry(label: t("usage.summary.currentStreak"), value: streakValue, detail: t("usage.summary.accountActivity")),
      UsageSummaryEntry(label: t("usage.summary.plan"), value: planValue, detail: t("usage.summary.signedInAccount")),
    ]
  }

  private static func routerSummary(
    source: UsageSourceEntry,
    range: Int,
    rangeTokens: Double,
    rangeRequests: Double?,
    _ t: Translator
  ) -> [UsageSummaryEntry] {
    var successRate: Double?
    if let requests = source.requests, requests != 0, let successful = source.successfulRequests {
      successRate = successful / requests * 100
    }
    let cacheHitRate: Double? = source.cacheTelemetrySeen == false
      ? nil
      : cacheHitRatePercent(cached: source.cachedInputTokens, input: source.inputTokens)
    let last24hTokens = source.last24hTokens
    let routerScope = nonEmpty(source.scopeLabel) ?? t("usage.scope.lastDays", ["days": ledgerDays])

    var items: [UsageSummaryEntry] = []
    if source.kind == .aggregate {
      items.append(UsageSummaryEntry(
        label: t("usage.summary.routerTotal"),
        value: optionalCompact(source.totalTokens, t),
        detail: t("usage.summary.routerTotalDetail", ["scope": routerScope]),
        tone: .total
      ))
    }

    // Last 24 hours.
    var last24Value = t("usage.summary.notMeasured")
    var last24Detail = t("usage.summary.rollingUnavailable")
    if let last24hTokens {
      last24Value = Format.compactNumber(last24hTokens, t)
      var text = t("usage.summary.routerTokens", ["count": Format.exactNumber(last24hTokens, t)])
      if let requests = source.last24hRequests {
        text += t("usage.summary.requestsSuffix", ["count": Format.exactNumber(requests, t)])
      }
      if let metered = source.last24hMeteredRequests, metered != source.last24hRequests {
        text += t("usage.summary.meteredSuffix", ["count": Format.exactNumber(metered, t)])
      }
      last24Detail = text
    }
    items.append(UsageSummaryEntry(label: t("usage.summary.last24h"), value: last24Value, detail: last24Detail))

    items.append(UsageSummaryEntry(
      label: t("usage.summary.lastRangeDays", ["range": range]),
      value: Format.compactNumber(rangeTokens, t),
      detail: t("usage.summary.rangeTokens", ["count": Format.exactNumber(rangeTokens, t)])
    ))

    if let rangeRequests {
      items.append(UsageSummaryEntry(
        label: t("usage.summary.requests"),
        value: Format.compactNumber(rangeRequests, t),
        detail: t("usage.summary.selectedRange", ["range": range])
      ))
    } else {
      items.append(UsageSummaryEntry(
        label: t("usage.summary.requests"),
        value: optionalCompact(source.requests, t),
        detail: t("usage.summary.notThisRange", ["scope": routerScope])
      ))
    }

    items.append(UsageSummaryEntry(
      label: t("usage.summary.regularInput"),
      value: optionalCompact(source.regularInputTokens, t),
      detail: t("usage.summary.cacheExcluded", ["scope": routerScope]),
      tone: .regular
    ))

    var cachedValue = optionalCompact(source.cachedInputTokens, t)
    var cachedDetail = t("usage.summary.cacheHitNotReported", ["scope": routerScope])
    if let cacheHitRate {
      cachedValue = "\(Format.compactNumber(source.cachedInputTokens, t)) (\(formatPercent(cacheHitRate)))"
      cachedDetail = t("usage.summary.cacheHitReported", ["scope": routerScope, "percent": formatPercent(cacheHitRate)])
    }
    items.append(UsageSummaryEntry(label: t("usage.summary.cachedInput"), value: cachedValue, detail: cachedDetail, tone: .cached))

    items.append(UsageSummaryEntry(
      label: t("usage.summary.output"),
      value: optionalCompact(source.outputTokens, t),
      detail: t("usage.summary.notThisRange", ["scope": routerScope]),
      tone: .output
    ))

    var successValue = t("usage.summary.notMeasured")
    if let successRate {
      successValue = String(format: "%.\(successRate < 99 ? 1 : 0)f", successRate) + "%"
    }
    let successDetail: String
    if let metered = source.meteredRequests {
      successDetail = t("usage.summary.meteredScope", ["count": Format.exactNumber(metered, t), "scope": routerScope])
    } else {
      successDetail = t("usage.summary.routerOutcomes", ["scope": routerScope])
    }
    items.append(UsageSummaryEntry(label: t("usage.summary.successful"), value: successValue, detail: successDetail))
    return items
  }

  // MARK: Allowances

  static func allowanceRows(sources: [UsageSourceEntry], selected: UsageSourceEntry) -> [UsageAllowanceEntry] {
    let candidates = sources.filter { $0.id == selected.id && $0.kind != .aggregate }
      + sources.filter { $0.id != selected.id && $0.kind != .aggregate }
    var rows: [UsageAllowanceEntry] = []
    for entry in candidates {
      for (index, metric) in entry.metrics.enumerated() {
        let label = nonEmpty(metric["label"]?.string) ?? metric["kind"]?.string ?? ""
        rows.append(UsageAllowanceEntry(
          id: "\(entry.id)-\(label)-\(index)",
          sourceID: entry.id,
          sourceName: entry.name,
          metric: metric
        ))
      }
    }
    return rows
  }

  /// The row a tray "resets" request should land on: the soonest reset of the
  /// requested source, else its first meter.
  static func targetAllowanceRowID(allowances: [UsageAllowanceEntry], targetSourceID: String?) -> String? {
    guard let targetSourceID else { return nil }
    let rows = allowances.filter { $0.sourceID == targetSourceID }
    var best: UsageAllowanceEntry?
    var bestReset = Double.infinity
    for row in rows {
      guard let reset = metricResetAt(row.metric) else { continue }
      if best == nil || reset < bestReset {
        best = row
        bestReset = reset
      }
    }
    return (best ?? rows.first)?.id
  }
}
