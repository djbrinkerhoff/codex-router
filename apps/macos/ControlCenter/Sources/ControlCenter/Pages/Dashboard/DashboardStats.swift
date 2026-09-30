import ControlCenterCore
import Foundation

// The Dashboard's presentation math, ported from the helpers at the bottom of
// DashboardPage.tsx. It stays a presentation view over the router's own
// snapshots: nothing here is a second accounting ledger.

enum DashboardRange: Int, CaseIterable, Hashable {
  case hours24 = 24
  case days7 = 7
  case days30 = 30

  var title: String {
    self == .hours24 ? "24h" : "\(rawValue)d"
  }
}

enum DashboardActivityMode: String, CaseIterable, Hashable {
  case daily, weekly, cumulative

  var messageId: String {
    switch self {
    case .daily: return "dashboard.mode.daily"
    case .weekly: return "dashboard.mode.weekly"
    case .cumulative: return "dashboard.mode.cumulative"
    }
  }
}

struct DashboardTrafficBucket: Equatable {
  var key: String
  var label: String
  var fullLabel: String
  var tokens: Double
  var requests: Double
  var measuredTokens: Bool
  var regularInputTokens: Double
  var cachedInputTokens: Double
  var outputTokens: Double
  var measuredBreakdown: Bool
}

struct DashboardTokenSplit {
  var regular: Double
  var cached: Double
  var output: Double
}

struct DashboardEventTokenBreakdown {
  var inputTokens: Double?
  var cachedInputTokens: Double?
  var outputTokens: Double?
}

struct DashboardTrafficPart: Equatable {
  enum Kind: String {
    case regularInput = "regular-input"
    case cachedInput = "cached-input"
    case output
    case other
  }

  var kind: Kind
  var label: String
  var tokens: Double
}

struct DashboardActivityDay: Equatable {
  var millis: Double
  var dateKey: String
  var tokens: Double
  var weekIndex: Int
  var dayIndex: Int
}

struct DashboardActivityViewDay: Equatable {
  var day: DashboardActivityDay
  var displayTokens: Double
  var tooltip: String
}

struct DashboardActivityMonth: Equatable {
  var label: String
  var weekIndex: Int
}

struct DashboardTokenActivityData {
  var days: [DashboardActivityDay]
  var months: [DashboardActivityMonth]
  var today: Double
}

enum DashboardBreakdownScope: Equatable {
  case rolling24h
  case ledger90
}

struct DashboardBreakdownRow: Equatable {
  var id: String
  var label: String
  var providerId: String?
  var provider: String?
  var tokens: Double
  var requests: Double
  var measuredTokens: Bool
  var scope: DashboardBreakdownScope
  var inputTokens: Double?
  var cachedInputTokens: Double?
  var outputTokens: Double?
  var tokensPerSecond: Double?
  var speedSampleCount: Int
}

private struct DashboardProviderEventRow {
  var requests: Double
  var tokens: Double
  var measuredTokens: Bool
}

private struct DashboardModelAccumulator {
  var id: String
  var label: String
  var providerId: String
  var provider: String
  var tokens: Double = 0
  var requests: Double = 0
  var measuredTokens = false
  var inputTotal: Double = 0
  var cachedTotal: Double = 0
  var outputTotal: Double = 0
  var inputMeasured = false
  var cacheMeasured = false
  var outputMeasured = false
  var speedSamples: [Double] = []
}

struct DashboardMetricEntry {
  var provider: String
  var label: String
  var metric: JSONValue
}

struct DashboardNextReset {
  var entry: DashboardMetricEntry
  var resetAt: JSONValue?
  var stamp: Double
}

struct DashboardLowestAllowance {
  var entry: DashboardMetricEntry
  var percent: Double
}

enum DashboardStats {
  static let recentEventLimit = 5
  static let tokenActivityWeeks = 53

  // MARK: Events

  static func recentWindowEvents(_ events: [DashboardEvent]?, now: Double) -> [DashboardEvent] {
    guard let events = events else { return [] }
    let cutoff = now - 24 * DashboardJS.hourMs
    return events.filter { event in
      guard let at = event.atMillis else { return false }
      return at >= cutoff && at <= now
    }
  }

  static func tokenCount(_ event: DashboardEvent) -> Double? {
    if let explicit = DashboardJS.optionalNumber(event.totalTokens) { return explicit }
    let input = DashboardJS.optionalNumber(DashboardJS.nullish(event.billedInputTokens) ?? event.inputTokens)
    let output = DashboardJS.optionalNumber(DashboardJS.nullish(event.billedOutputTokens) ?? event.outputTokens)
    if input != nil || output != nil { return (input ?? 0) + (output ?? 0) }
    return nil
  }

  static func tokenBreakdown(_ event: DashboardEvent) -> DashboardEventTokenBreakdown {
    let input = DashboardJS.optionalNumber(DashboardJS.nullish(event.billedInputTokens) ?? event.inputTokens)
    let cached = DashboardJS.optionalNumber(event.cachedInputTokens)
    let output = DashboardJS.optionalNumber(DashboardJS.nullish(event.billedOutputTokens) ?? event.outputTokens)
    var cachedResult: Double?
    if let cached = cached {
      if let input = input {
        cachedResult = min(input, cached)
      } else {
        cachedResult = cached
      }
    }
    return DashboardEventTokenBreakdown(inputTokens: input, cachedInputTokens: cachedResult, outputTokens: output)
  }

  private static func split(input: Double?, cached: Double?, output: Double?) -> DashboardTokenSplit? {
    if input == nil && cached == nil && output == nil { return nil }
    let inputTokens = input ?? 0
    let cachedInputTokens = input == nil ? (cached ?? 0) : min(inputTokens, cached ?? 0)
    return DashboardTokenSplit(
      regular: max(0, inputTokens - cachedInputTokens),
      cached: cachedInputTokens,
      output: output ?? 0
    )
  }

  static func tokenSplit(_ event: DashboardEvent) -> DashboardTokenSplit? {
    split(
      input: DashboardJS.optionalNumber(DashboardJS.nullish(event.billedInputTokens) ?? event.inputTokens),
      cached: DashboardJS.optionalNumber(event.cachedInputTokens),
      output: DashboardJS.optionalNumber(DashboardJS.nullish(event.billedOutputTokens) ?? event.outputTokens)
    )
  }

  static func tokenSplit(bucket: JSONValue) -> DashboardTokenSplit? {
    split(
      input: DashboardJS.optionalNumber(bucket["inputTokens"]),
      cached: DashboardJS.optionalNumber(bucket["cachedInputTokens"]),
      output: DashboardJS.optionalNumber(bucket["outputTokens"])
    )
  }

  static func tokensPerSecond(_ event: DashboardEvent) -> Double? {
    guard let output = DashboardJS.optionalNumber(event.outputTokens), output > 0,
      let durationMs = DashboardJS.optionalNumber(event.durationMs), durationMs > 0,
      let firstTokenMs = DashboardJS.optionalNumber(event.firstTokenMs)
    else { return nil }
    guard let status = event.status, status >= 200, status < 400 else { return nil }
    if event.speedDisqualified { return nil }
    let generationDurationMs = durationMs - firstTokenMs
    if generationDurationMs <= 0 { return nil }
    // Same rule as provider-usage.mjs: count the tokens generated inside the
    // timed window. Reasoning that was streamed started the clock, so it stays
    // in; reasoning that ran silently before the first visible token belongs to
    // TTFT and is subtracted. A reasoning count above the output count means
    // the provider reports visible tokens only, so the inclusive total is
    // rebuilt.
    let reasoningTokens = max(0, DashboardJS.optionalNumber(event.reasoningTokens) ?? 0)
    let inclusiveOutput = reasoningTokens > output ? output + reasoningTokens : output
    let speedOutput = event.reasoningStreamed == false
      ? max(0, inclusiveOutput - reasoningTokens)
      : inclusiveOutput
    let rate = (speedOutput * 1_000) / generationDurationMs
    return rate.isFinite && rate <= 500 ? (rate * 10).rounded() / 10 : nil
  }

  static func median(_ values: [Double]) -> Double? {
    let sorted = values.filter { $0.isFinite }.sorted()
    if sorted.isEmpty { return nil }
    return (sorted[sorted.count / 2] * 10).rounded() / 10
  }

  static func sumEventTokens(_ events: [DashboardEvent]) -> Double? {
    var total = 0.0
    var measured = false
    for event in events {
      guard let tokens = tokenCount(event) else { continue }
      total += tokens
      measured = true
    }
    return measured ? total : nil
  }

  /// Nil when no source reported the field at all, so a build that cannot
  /// measure a value never renders as a confident zero.
  static func sumReported(_ values: [JSONValue?]) -> Double? {
    var total = 0.0
    var reported = false
    for value in values where DashboardJS.isFiniteNumber(value) {
      total += DashboardJS.number(value)
      reported = true
    }
    return reported ? total : nil
  }

  // MARK: Labels

  static func formatTokensPerSecond(_ value: Double) -> String {
    String(format: "%.1f tok/s", value)
  }

  static func formatEventTokenFacts(total: Double?, breakdown: DashboardEventTokenBreakdown, t: Translator) -> String {
    var facts: [String] = []
    if let total = total { facts.append(t("dashboard.facts.tok", ["count": Format.compactNumber(total, t)])) }
    if let input = breakdown.inputTokens { facts.append(t("dashboard.facts.input", ["count": Format.compactNumber(input, t)])) }
    if let cached = breakdown.cachedInputTokens { facts.append(t("dashboard.facts.cache", ["count": Format.compactNumber(cached, t)])) }
    if let output = breakdown.outputTokens { facts.append(t("dashboard.facts.output", ["count": Format.compactNumber(output, t)])) }
    return facts.isEmpty ? t("dashboard.facts.none") : facts.joined(separator: " · ")
  }

  static func shortModelName(_ model: String) -> String {
    let last = model.split(separator: "/").last.map(String.init)
    if let last = last, !last.isEmpty { return last }
    return model
  }

  static func friendlyPlanName(_ value: String) -> String {
    var result = ""
    var previousIsWord = false
    for character in value.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression) {
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

  static func activityLabel(_ state: String, _ t: Translator) -> String {
    if state == "generating" { return t("status.activity.thinking") }
    if state == "starting" { return t("status.activity.starting") }
    if state == "error" { return t("status.activity.error") }
    if state == "offline" { return t("status.activity.offline") }
    return t("status.activity.idle")
  }

  static func limitWindowLabel(_ minutes: JSONValue?, index: Int, _ t: Translator) -> String {
    let value = DashboardJS.number(minutes)
    if !value.isFinite {
      return index == 0 ? t("status.limit.primary") : t("status.limit.secondary")
    }
    if value >= 1_440 && value.truncatingRemainder(dividingBy: 1_440) == 0 {
      let days = value / 1_440
      if days == 1 { return t("status.limit.daily") }
      if days == 7 { return t("status.limit.weekly") }
      return t("status.limit.days", ["days": DashboardJS.string(days)])
    }
    if value >= 60 && value.truncatingRemainder(dividingBy: 60) == 0 {
      return t("status.limit.hours", ["hours": DashboardJS.string(value / 60)])
    }
    return t("status.limit.minutes", ["minutes": DashboardJS.string(value)])
  }

  /// Seconds or milliseconds since the epoch, or a date string, as
  /// milliseconds; nil when unreadable (`NaN` in the renderer).
  static func timestamp(_ value: JSONValue?) -> Double? {
    guard let date = Format.date(value) else { return nil }
    return date.timeIntervalSince1970 * 1_000
  }

  static func resetCountdown(_ value: JSONValue?, now: Double, _ t: Translator) -> String {
    guard let stamp = timestamp(value) else { return t("status.countdown.unavailable") }
    let remaining = stamp - now
    if remaining <= 0 { return t("status.countdown.refreshDue") }
    let minuteCount = (remaining / 60_000).rounded(.up)
    if !minuteCount.isFinite || minuteCount > 1e12 { return t("status.countdown.unavailable") }
    let minutes = Int(minuteCount)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h \(minutes % 60)m" }
    let days = hours / 24
    return "\(days)d \(hours % 24)h"
  }

  static func trafficRangeLabel(_ range: DashboardRange, _ t: Translator) -> String {
    range == .hours24
      ? t("dashboard.range.last24h")
      : t("dashboard.range.lastDays", ["range": range.rawValue])
  }

  static func trafficDescription(_ range: DashboardRange, _ t: Translator) -> String {
    range == .hours24 ? t("dashboard.traffic.hourly") : t("dashboard.traffic.daily")
  }

  // MARK: Metrics

  static func collectMetrics(t: Translator, account: JSONValue?, providerUsage: JSONValue?) -> [DashboardMetricEntry] {
    var entries: [DashboardMetricEntry] = []
    let windows: [JSONValue?] = [account?["primary"], account?["secondary"]]
    for (index, candidate) in windows.enumerated() {
      guard let metric = candidate, metric.truthy else { continue }
      entries.append(DashboardMetricEntry(
        provider: "ChatGPT",
        label: limitWindowLabel(metric["windowDurationMins"], index: index, t),
        metric: metric
      ))
    }
    let usageProviders = providerUsage?["providers"]?.items ?? []
    for provider in usageProviders {
      let metrics = provider["account"]?["metrics"]?.items ?? []
      for metric in metrics {
        let backendLabel = t.backend(metric["label"]?.string)
        entries.append(DashboardMetricEntry(
          provider: provider["displayName"]?.string ?? "",
          label: backendLabel.isEmpty ? t("status.usageLimit") : backendLabel,
          metric: metric
        ))
      }
    }
    return entries
  }

  static func resetAtOf(_ metric: JSONValue) -> JSONValue? {
    DashboardJS.nullish(metric["resetAt"]) ?? metric["resetsAt"]
  }

  /// The soonest reset still in the future; the first entry wins a tie.
  static func nextReset(_ metrics: [DashboardMetricEntry], now: Double) -> DashboardNextReset? {
    var best: DashboardNextReset?
    for entry in metrics {
      let reset = resetAtOf(entry.metric)
      guard let stamp = timestamp(reset), stamp > now else { continue }
      if let current = best, current.stamp <= stamp { continue }
      best = DashboardNextReset(entry: entry, resetAt: reset, stamp: stamp)
    }
    return best
  }

  /// The least remaining share; the first entry wins a tie.
  static func lowestAllowance(_ metrics: [DashboardMetricEntry]) -> DashboardLowestAllowance? {
    var best: DashboardLowestAllowance?
    for entry in metrics {
      guard let percent = Format.remainingPercent(entry.metric) else { continue }
      if let current = best, current.percent <= percent { continue }
      best = DashboardLowestAllowance(entry: entry, percent: percent)
    }
    return best
  }

  // MARK: Traffic

  static func retainedOrCurrentProviders(_ providerUsage: JSONValue?) -> [JSONValue] {
    let retained = providerUsage?["retained"]?["providers"]?.items ?? []
    if !retained.isEmpty { return retained }
    return providerUsage?["providers"]?.items ?? []
  }

  static func buildTrafficBuckets(
    events: [DashboardEvent]?,
    providerUsage: JSONValue?,
    hours: [JSONValue]?,
    range: DashboardRange,
    now: Double,
    t: Translator
  ) -> [DashboardTrafficBucket] {
    if range == .hours24 {
      return buildHourlyTrafficBuckets(events: events, hours: hours, now: now, t: t)
    }
    return buildDailyTrafficBuckets(events: events, providerUsage: providerUsage, range: range.rawValue, now: now, t: t)
  }

  private static func emptyBucket(key: String, label: String, fullLabel: String) -> DashboardTrafficBucket {
    DashboardTrafficBucket(
      key: key,
      label: label,
      fullLabel: fullLabel,
      tokens: 0,
      requests: 0,
      measuredTokens: false,
      regularInputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      measuredBreakdown: false
    )
  }

  private static func add(_ event: DashboardEvent, to bucket: inout DashboardTrafficBucket) {
    bucket.requests += 1
    if let tokens = tokenCount(event) {
      bucket.tokens += tokens
      bucket.measuredTokens = true
    }
    if let split = tokenSplit(event) {
      bucket.regularInputTokens += split.regular
      bucket.cachedInputTokens += split.cached
      bucket.outputTokens += split.output
      bucket.measuredBreakdown = true
    }
  }

  /// `events` is a bounded sample -- the router caps it at 1,000 rows -- so on
  /// a busy day it covers a couple of hours, not twenty-four. The router now
  /// publishes an hourly rollup over the uncapped window; the sample remains
  /// the fallback for a router that predates it.
  private static func hourlyBucketsFromRollup(_ hours: [JSONValue], t: Translator) -> [DashboardTrafficBucket] {
    let labelFormatter = DashboardFormatters.make(locale: t.locale, template: "j", utc: false)
    let fullFormatter = DashboardFormatters.make(locale: t.locale, template: "MMMdj", utc: false)
    // Label each bar from the hour the router actually measured rather than
    // from a grid anchored on this app's clock.
    var buckets: [DashboardTrafficBucket] = []
    for hour in hours {
      let startedAt = hour["startedAt"]?.string ?? ""
      var label = ""
      var fullLabel = ""
      if let start = DashboardTime.millis(startedAt) {
        let date = DashboardTime.date(millis: start)
        label = labelFormatter.string(from: date)
        fullLabel = fullFormatter.string(from: date)
      }
      buckets.append(DashboardTrafficBucket(
        key: startedAt,
        label: label,
        fullLabel: fullLabel,
        tokens: DashboardJS.numberOrZero(hour["tokens"]),
        requests: DashboardJS.numberOrZero(hour["requests"]),
        measuredTokens: hour["measuredTokens"].truthy,
        regularInputTokens: DashboardJS.numberOrZero(hour["regularInputTokens"]),
        cachedInputTokens: DashboardJS.numberOrZero(hour["cachedInputTokens"]),
        outputTokens: DashboardJS.numberOrZero(hour["outputTokens"]),
        measuredBreakdown: hour["measuredBreakdown"].truthy
      ))
    }
    return buckets
  }

  private static func buildHourlyTrafficBuckets(
    events: [DashboardEvent]?,
    hours: [JSONValue]?,
    now: Double,
    t: Translator
  ) -> [DashboardTrafficBucket] {
    if let hours = hours, !hours.isEmpty { return hourlyBucketsFromRollup(hours, t: t) }
    let windowStart = now - 24 * DashboardJS.hourMs
    let first = DashboardTime.localHourStart(windowStart)
    let lastHour = DashboardTime.localHourStart(now)
    let lastBucket = now == lastHour ? lastHour - DashboardJS.hourMs : lastHour
    let bucketCount = max(0, Int(((lastBucket - first) / DashboardJS.hourMs).rounded(.down)) + 1)
    let labelFormatter = DashboardFormatters.make(locale: t.locale, template: "j", utc: false)
    let fullFormatter = DashboardFormatters.make(locale: t.locale, template: "MMMdj", utc: false)
    var buckets: [DashboardTrafficBucket] = []
    for index in 0..<bucketCount {
      let start = first + Double(index) * DashboardJS.hourMs
      let date = DashboardTime.date(millis: start)
      buckets.append(emptyBucket(
        key: DashboardJS.string(start),
        label: labelFormatter.string(from: date),
        fullLabel: fullFormatter.string(from: date)
      ))
    }
    for event in events ?? [] {
      guard let at = event.atMillis, at >= windowStart, at < now else { continue }
      let index = Int(((at - first) / DashboardJS.hourMs).rounded(.down))
      if index < 0 || index >= buckets.count { continue }
      add(event, to: &buckets[index])
    }
    return buckets
  }

  private static func indexForUsageDay(_ value: JSONValue?, first: Double, count: Int) -> Int? {
    guard let text = value?.string, let stamp = DashboardTime.millis("\(text)T00:00:00Z") else { return nil }
    let index = Int(((stamp - first) / DashboardJS.dayMs).rounded(.down))
    return index >= 0 && index < count ? index : nil
  }

  private static func buildDailyTrafficBuckets(
    events: [DashboardEvent]?,
    providerUsage: JSONValue?,
    range: Int,
    now: Double,
    t: Translator
  ) -> [DashboardTrafficBucket] {
    // Daily buckets are keyed by UTC day, both by the router and by OpenAI's
    // account stream. Grid and labels are UTC so a bar names the day its
    // number is from.
    let anchor = (now / DashboardJS.dayMs).rounded(.down) * DashboardJS.dayMs
    let first = anchor - Double(range - 1) * DashboardJS.dayMs
    let labelFormatter = DashboardFormatters.make(locale: t.locale, template: "MMMd", utc: true)
    let fullFormatter = DashboardFormatters.make(locale: t.locale, template: range == 30 ? "MMMdyyyy" : "MMMd", utc: true)
    var buckets: [DashboardTrafficBucket] = []
    for index in 0..<range {
      let start = first + Double(index) * DashboardJS.dayMs
      let date = DashboardTime.date(millis: start)
      buckets.append(emptyBucket(
        key: DashboardJS.string(start),
        label: labelFormatter.string(from: date),
        fullLabel: fullFormatter.string(from: date)
      ))
    }

    var providerBuckets = 0
    for provider in retainedOrCurrentProviders(providerUsage) {
      let usageBuckets = provider["dailyUsageBuckets"]?.items ?? []
      for usageBucket in usageBuckets {
        guard let index = indexForUsageDay(usageBucket["startDate"], first: first, count: range) else { continue }
        providerBuckets += 1
        if let tokens = DashboardJS.optionalNumber(usageBucket["tokens"]) {
          buckets[index].tokens += tokens
          buckets[index].measuredTokens = true
        }
        if let requests = DashboardJS.optionalNumber(usageBucket["requests"]) {
          buckets[index].requests += requests
        }
        if let split = tokenSplit(bucket: usageBucket) {
          buckets[index].regularInputTokens += split.regular
          buckets[index].cachedInputTokens += split.cached
          buckets[index].outputTokens += split.output
          buckets[index].measuredBreakdown = true
        }
      }
    }

    // A mixed-version snapshot can have no daily provider rows yet. Keep the
    // chart useful while it catches up by deriving the same daily shape from
    // the bounded event details, without adding those events to provider rows.
    if providerBuckets == 0 {
      for event in events ?? [] {
        guard let at = event.atMillis, at >= first, at < anchor + DashboardJS.dayMs else { continue }
        let index = Int(((at - first) / DashboardJS.dayMs).rounded(.down))
        if index < 0 || index >= buckets.count { continue }
        add(event, to: &buckets[index])
      }
    }
    return buckets
  }

  static func trafficParts(_ bucket: DashboardTrafficBucket, _ t: Translator) -> [DashboardTrafficPart] {
    let known = bucket.regularInputTokens + bucket.cachedInputTokens + bucket.outputTokens
    return [
      DashboardTrafficPart(kind: .regularInput, label: t("usage.token.regularInput"), tokens: bucket.regularInputTokens),
      DashboardTrafficPart(kind: .cachedInput, label: t("usage.token.cachedInput"), tokens: bucket.cachedInputTokens),
      DashboardTrafficPart(kind: .output, label: t("usage.token.output"), tokens: bucket.outputTokens),
      DashboardTrafficPart(kind: .other, label: t("usage.token.other"), tokens: max(0, bucket.tokens - known)),
    ]
  }

  // MARK: Breakdowns

  private static func sortedRows(_ rows: [DashboardBreakdownRow]) -> [DashboardBreakdownRow] {
    let indexed = rows.enumerated().sorted { left, right in
      if left.element.tokens != right.element.tokens { return left.element.tokens > right.element.tokens }
      if left.element.requests != right.element.requests { return left.element.requests > right.element.requests }
      return left.offset < right.offset
    }
    return indexed.map { $0.element }
  }

  private static func displayNames(_ providerUsage: JSONValue?) -> [String: String] {
    var names: [String: String] = [:]
    for provider in providerUsage?["providers"]?.items ?? [] {
      if let id = provider["id"]?.string { names[id] = provider["displayName"]?.string ?? "" }
    }
    return names
  }

  static func buildProviderBreakdown(providerUsage: JSONValue?, events: [DashboardEvent]?, now: Double) -> [DashboardBreakdownRow] {
    var eventRows = DashboardOrderedMap<DashboardProviderEventRow>()
    for event in recentWindowEvents(events, now: now) {
      let id = event.provider ?? "unknown"
      var previous = eventRows[id] ?? DashboardProviderEventRow(requests: 0, tokens: 0, measuredTokens: false)
      previous.requests += 1
      if let tokens = tokenCount(event) {
        previous.tokens += tokens
        previous.measuredTokens = true
      }
      eventRows[id] = previous
    }
    let names = displayNames(providerUsage)
    var rows = DashboardOrderedMap<DashboardBreakdownRow>()
    for provider in providerUsage?["providers"]?.items ?? [] {
      guard let providerId = provider["id"]?.string else { continue }
      let eventRow = eventRows[providerId]
      let snapshotRequests = DashboardJS.optionalNumber(provider["last24hRequests"])
      let snapshotTokens = DashboardJS.optionalNumber(provider["last24hTokens"])
      // A health snapshot and the event stream can be sampled a few
      // milliseconds apart. Preserve the larger observed value instead of
      // briefly painting a provider as idle while the other source already
      // has its latest request.
      let requests = max(snapshotRequests ?? 0, eventRow?.requests ?? 0)
      let eventMeasured = eventRow?.measuredTokens ?? false
      let measuredTokens = snapshotTokens != nil || eventMeasured
      let tokens = max(snapshotTokens ?? 0, eventRow?.tokens ?? 0)
      if requests <= 0 && tokens <= 0 && !eventMeasured { continue }
      rows[providerId] = DashboardBreakdownRow(
        id: "provider:\(providerId)",
        label: provider["displayName"]?.string ?? providerId,
        providerId: providerId,
        provider: nil,
        tokens: tokens,
        requests: requests,
        measuredTokens: measuredTokens,
        scope: .rolling24h,
        inputTokens: nil,
        cachedInputTokens: nil,
        outputTokens: nil,
        tokensPerSecond: nil,
        speedSampleCount: 0
      )
    }
    for providerId in eventRows.keys {
      guard let eventRow = eventRows[providerId] else { continue }
      if rows[providerId] != nil || (eventRow.requests <= 0 && !eventRow.measuredTokens) { continue }
      var label = providerId
      if let name = names[providerId], !name.isEmpty { label = name }
      rows[providerId] = DashboardBreakdownRow(
        id: "provider:\(providerId)",
        label: label,
        providerId: providerId,
        provider: nil,
        tokens: eventRow.tokens,
        requests: eventRow.requests,
        measuredTokens: eventRow.measuredTokens,
        scope: .rolling24h,
        inputTokens: nil,
        cachedInputTokens: nil,
        outputTokens: nil,
        tokensPerSecond: nil,
        speedSampleCount: 0
      )
    }
    return sortedRows(rows.values)
  }

  static func buildModelBreakdown(providerUsage: JSONValue?, events: [DashboardEvent]?, now: Double) -> [DashboardBreakdownRow] {
    let names = displayNames(providerUsage)
    var eventRows = DashboardOrderedMap<DashboardModelAccumulator>()
    for event in recentWindowEvents(events, now: now) {
      let model = event.model ?? "unknown"
      let provider = event.provider ?? "unknown"
      let id = "\(provider):\(model)"
      var providerName = provider
      if let name = names[provider], !name.isEmpty { providerName = name }
      var previous = eventRows[id] ?? DashboardModelAccumulator(
        id: id,
        label: shortModelName(model),
        providerId: provider,
        provider: providerName
      )
      previous.requests += 1
      if let tokens = tokenCount(event) {
        previous.tokens += tokens
        previous.measuredTokens = true
      }
      let breakdown = tokenBreakdown(event)
      if let input = breakdown.inputTokens {
        previous.inputTotal += input
        previous.inputMeasured = true
      }
      if let cached = breakdown.cachedInputTokens {
        previous.cachedTotal += cached
        previous.cacheMeasured = true
      }
      if let output = breakdown.outputTokens {
        previous.outputTotal += output
        previous.outputMeasured = true
      }
      if let speed = tokensPerSecond(event) { previous.speedSamples.append(speed) }
      eventRows[id] = previous
    }
    if !eventRows.isEmpty {
      var rows: [DashboardBreakdownRow] = []
      for row in eventRows.values {
        rows.append(DashboardBreakdownRow(
          id: row.id,
          label: row.label,
          providerId: row.providerId,
          provider: row.provider,
          tokens: row.tokens,
          requests: row.requests,
          measuredTokens: row.measuredTokens,
          scope: .rolling24h,
          inputTokens: row.inputMeasured ? row.inputTotal : nil,
          cachedInputTokens: row.cacheMeasured ? row.cachedTotal : nil,
          outputTokens: row.outputMeasured ? row.outputTotal : nil,
          tokensPerSecond: median(row.speedSamples),
          speedSampleCount: row.speedSamples.count
        ))
      }
      return sortedRows(rows)
    }

    // The event stream may be empty while the provider snapshot still has a
    // useful long-window model ledger (for example after the app was
    // reopened). Keep that fallback explicitly labelled so the UI never
    // implies it is a rolling 24-hour figure.
    var fallback: [DashboardBreakdownRow] = []
    for provider in providerUsage?["providers"]?.items ?? [] {
      let providerId = provider["id"]?.string ?? ""
      for model in provider["models"]?.items ?? [] {
        let requests = DashboardJS.numberOrZero(model["requests"])
        let totalTokens = DashboardJS.numberOrZero(model["totalTokens"])
        if !(requests > 0 || totalTokens > 0) { continue }
        let slug = DashboardJS.nonEmpty(model["slug"])
        let displayName = DashboardJS.nonEmpty(model["displayName"])
        let idPart = slug ?? displayName ?? "unknown"
        let label = displayName ?? shortModelName(slug ?? "unknown")
        fallback.append(DashboardBreakdownRow(
          id: "\(providerId):\(idPart)",
          label: label,
          providerId: providerId,
          provider: provider["displayName"]?.string ?? "",
          tokens: totalTokens,
          requests: requests,
          measuredTokens: DashboardJS.isFiniteNumber(model["totalTokens"]),
          scope: .ledger90,
          inputTokens: DashboardJS.isFiniteNumber(model["inputTokens"]) ? DashboardJS.number(model["inputTokens"]) : nil,
          cachedInputTokens: nil,
          outputTokens: DashboardJS.isFiniteNumber(model["outputTokens"]) ? DashboardJS.number(model["outputTokens"]) : nil,
          tokensPerSecond: DashboardJS.isFiniteNumber(model["observedTokensPerSecond"])
            ? DashboardJS.number(model["observedTokensPerSecond"])
            : nil,
          speedSampleCount: DashboardJS.safeInt(DashboardJS.numberOrZero(model["speedSampleCount"]))
        ))
      }
    }
    return sortedRows(fallback)
  }

  static func modelBreakdownScopeTitle(_ rows: [DashboardBreakdownRow], _ t: Translator) -> String {
    rows.first?.scope == .ledger90 ? t("dashboard.mix.modelsLedger") : t("dashboard.mix.models24h")
  }

  // MARK: Token activity

  /// One year of daily tokens laid out as a week-per-column grid, ending in
  /// the current UTC week.
  static func buildTokenActivity(
    events: [DashboardEvent]?,
    providerUsage: JSONValue?,
    now: Double,
    t: Translator
  ) -> DashboardTokenActivityData {
    let today = (now / DashboardJS.dayMs).rounded(.down) * DashboardJS.dayMs
    let sundayOffset = Double(DashboardTime.weekday(today)) * DashboardJS.dayMs
    let historyOffset = Double((tokenActivityWeeks - 1) * 7) * DashboardJS.dayMs
    let first = today - sundayOffset - historyOffset

    var tokensByDay: [String: Double] = [:]
    var dailyRows = 0
    for provider in retainedOrCurrentProviders(providerUsage) {
      for bucket in provider["dailyUsageBuckets"]?.items ?? [] {
        guard let dateKey = DashboardTime.normalizedDateKey(bucket["startDate"]) else { continue }
        dailyRows += 1
        tokensByDay[dateKey, default: 0] += max(0, DashboardJS.numberOrZero(bucket["tokens"]))
      }
    }

    if dailyRows == 0 {
      for event in events ?? [] {
        guard let at = event.atMillis else { continue }
        guard let tokens = tokenCount(event) else { continue }
        tokensByDay[DashboardTime.dayKey(at), default: 0] += tokens
      }
    }

    var days: [DashboardActivityDay] = []
    for index in 0..<(tokenActivityWeeks * 7) {
      let millis = first + Double(index) * DashboardJS.dayMs
      let dateKey = DashboardTime.dayKey(millis)
      days.append(DashboardActivityDay(
        millis: millis,
        dateKey: dateKey,
        tokens: tokensByDay[dateKey] ?? 0,
        weekIndex: index / 7,
        dayIndex: DashboardTime.weekday(millis)
      ))
    }

    let monthFormatter = DashboardFormatters.make(locale: t.locale, template: "MMM", utc: true)
    var months: [DashboardActivityMonth] = []
    var previousMonth = -1
    for day in days {
      let parts = DashboardTime.utcCalendar.dateComponents([.month, .day], from: DashboardTime.date(millis: day.millis))
      let month = parts.month ?? 0
      if month == previousMonth { continue }
      previousMonth = month
      if (parts.day ?? 1) > 7 { continue }
      months.append(DashboardActivityMonth(
        label: monthFormatter.string(from: DashboardTime.date(millis: day.millis)),
        weekIndex: day.weekIndex
      ))
    }
    return DashboardTokenActivityData(days: days, months: months, today: today)
  }

  static func tokenActivityForMode(
    _ days: [DashboardActivityDay],
    mode: DashboardActivityMode,
    t: Translator
  ) -> [DashboardActivityViewDay] {
    let dateFormatter = DashboardFormatters.make(locale: t.locale, template: "MMMdyyyy", utc: true)
    var weeklyTotals: [Int: Double] = [:]
    for day in days {
      weeklyTotals[day.weekIndex, default: 0] += day.tokens
    }

    var cumulative = 0.0
    var result: [DashboardActivityViewDay] = []
    for day in days {
      cumulative += day.tokens
      switch mode {
      case .weekly:
        let startIndex = day.weekIndex * 7
        let endIndex = day.weekIndex * 7 + 6
        let weekStart = startIndex < days.count ? days[startIndex].millis : day.millis
        let weekEnd = endIndex < days.count ? days[endIndex].millis : day.millis
        let displayTokens = weeklyTotals[day.weekIndex] ?? 0
        result.append(DashboardActivityViewDay(
          day: day,
          displayTokens: displayTokens,
          tooltip: t("dashboard.activity.weeklyTooltip", [
            "count": Format.exactNumber(displayTokens, t),
            "start": dateFormatter.string(from: DashboardTime.date(millis: weekStart)),
            "end": dateFormatter.string(from: DashboardTime.date(millis: weekEnd)),
          ])
        ))
      case .cumulative:
        result.append(DashboardActivityViewDay(
          day: day,
          displayTokens: cumulative,
          tooltip: t("dashboard.activity.cumulativeTooltip", [
            "count": Format.exactNumber(cumulative, t),
            "date": dateFormatter.string(from: DashboardTime.date(millis: day.millis)),
          ])
        ))
      case .daily:
        result.append(DashboardActivityViewDay(
          day: day,
          displayTokens: day.tokens,
          tooltip: t("dashboard.activity.dailyTooltip", [
            "count": Format.exactNumber(day.tokens, t),
            "date": dateFormatter.string(from: DashboardTime.date(millis: day.millis)),
          ])
        ))
      }
    }
    return result
  }

  static func tokenActivityMax(_ values: [Double]) -> Double {
    var maximum = 0.0
    for value in values where value.isFinite && value > maximum {
      maximum = value
    }
    return maximum
  }

  static func levelForTokenActivity(_ tokens: Double, max maximum: Double) -> Int {
    if tokens <= 0 || maximum <= 0 { return 0 }
    let scaled = (log1p(tokens) / log1p(maximum)) * 4
    if !scaled.isFinite { return tokens.isInfinite ? 4 : 0 }
    return Swift.max(1, Swift.min(4, Int(scaled.rounded(.up))))
  }
}
