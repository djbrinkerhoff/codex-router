import Foundation

/// Display formatting shared by every page, ported from
/// `apps/control-center/src/lib.ts` so numbers read the same in both windows.
public enum Format {
  static func trim(_ value: Double, _ digits: Int) -> String {
    let text = String(format: "%.\(digits)f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }

  static func grouped(_ value: Double, _ t: Translator) -> String {
    let formatter = NumberFormatter()
    formatter.locale = t.locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
  }

  public static func compactNumber(_ value: Double?, _ t: Translator) -> String {
    let number = max(0, value ?? 0)
    if number < 1_000 { return grouped(number, t) }
    if number < 1_000_000 { return "\(trim(number / 1_000, number < 10_000 ? 1 : 0))k" }
    if number < 1_000_000_000 { return "\(trim(number / 1_000_000, number < 10_000_000 ? 1 : 0))m" }
    return "\(trim(number / 1_000_000_000, number < 10_000_000_000 ? 1 : 0))b"
  }

  public static func exactNumber(_ value: Double?, _ t: Translator) -> String {
    grouped(max(0, (value ?? 0).rounded()), t)
  }

  public static func context(_ value: Double?, _ t: Translator) -> String {
    guard let value, value > 0 else { return t("common.managed") }
    return t("common.tokensCount", ["count": compactNumber(value, t)])
  }

  static let effortKeys: [String: String] = [
    "default": "models.effort.default",
    "none": "models.effort.none",
    "minimal": "models.effort.minimal",
    "low": "models.effort.low",
    "medium": "models.effort.medium",
    "high": "models.effort.high",
    "xhigh": "models.effort.xhigh",
    "max": "models.effort.max",
    "ultra": "models.effort.ultra",
  ]

  /// An unknown rung is a newer router than this build; its id beats an
  /// invented name.
  public static func effortLabel(_ effort: String, _ t: Translator) -> String {
    guard let key = effortKeys[effort] else { return effort }
    if effort == "default" { return t(key) }
    return t.isChinese ? "\(t(key)) (\(effort))" : effort
  }

  public static func bytesGb(_ value: Double?, _ t: Translator) -> String {
    guard let value else { return t("common.sizeUnknown") }
    return "\(String(format: "%.\(value < 10 ? 1 : 0)f", value)) GB"
  }

  /// Seconds or milliseconds since the epoch, or an ISO string.
  public static func date(_ value: JSONValue?) -> Date? {
    guard let value, !value.isNull else { return nil }
    if let number = value.double {
      return Date(timeIntervalSince1970: number < 10_000_000_000 ? number : number / 1_000)
    }
    guard let text = value.text else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = fractional.date(from: text) { return parsed }
    let plain = ISO8601DateFormatter()
    if let parsed = plain.date(from: text) { return parsed }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: text)
  }

  public static func dateTime(_ value: JSONValue?, _ t: Translator) -> String {
    guard let date = date(value) else { return t("common.notReported") }
    let formatter = DateFormatter()
    formatter.locale = t.locale
    formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
    return formatter.string(from: date)
  }

  public static func duration(_ milliseconds: Double?, _ t: Translator) -> String {
    let value = max(0, milliseconds ?? 0)
    if value < 1_000 { return t("common.durationMs", ["count": Int(value.rounded())]) }
    if value < 60_000 {
      return t("common.durationSeconds", ["count": String(format: "%.\(value < 10_000 ? 1 : 0)f", value / 1_000)])
    }
    let minutes = Int(value / 60_000)
    let seconds = Int((value.truncatingRemainder(dividingBy: 60_000) / 1_000).rounded())
    return t("common.durationMinutesSeconds", ["minutes": minutes, "seconds": seconds])
  }

  public static func balance(_ value: Double, currency: String?, _ t: Translator) -> String {
    let code = currency?.trimmingCharacters(in: .whitespaces).isEmpty == false
      ? currency!.trimmingCharacters(in: .whitespaces)
      : "USD"
    // Venice reports a DIEM ledger that is not an ISO 4217 code.
    if Locale.commonISOCurrencyCodes.contains(code.uppercased()) {
      let formatter = NumberFormatter()
      formatter.locale = t.locale
      formatter.numberStyle = .currency
      formatter.currencyCode = code.uppercased()
      formatter.maximumFractionDigits = 2
      if let text = formatter.string(from: NSNumber(value: value)) { return text }
    }
    let formatter = NumberFormatter()
    formatter.locale = t.locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) \(code)"
  }

  /// A provider usage metric (`UsageMetric` in types.ts) as "% left",
  /// "N left", a balance, or "Reported".
  public static func metricValue(_ metric: JSONValue, _ t: Translator) -> String {
    if metric["kind"]?.string == "balance", let value = metric["value"]?.double {
      return balance(value, currency: metric["currency"]?.string, t)
    }
    if let remaining = metric["remainingPercent"]?.double {
      return t("common.percentLeft", ["percent": Int(remaining.rounded())])
    }
    if let used = metric["usedPercent"]?.double {
      return t("common.percentLeft", ["percent": Int((100 - used).rounded())])
    }
    if let remaining = metric["remaining"]?.double {
      return t("common.countLeft", ["count": compactNumber(remaining, t)])
    }
    return t("common.reported")
  }

  public static func remainingPercent(_ metric: JSONValue) -> Double? {
    func clamp(_ value: Double) -> Double { min(100, max(0, value)) }
    if let value = metric["remainingPercent"]?.double { return clamp(value) }
    if let used = metric["usedPercent"]?.double { return clamp(100 - used) }
    if let remaining = metric["remaining"]?.double, let limit = metric["limit"]?.double, limit > 0 {
      return clamp(remaining / limit * 100)
    }
    return nil
  }

  /// A usage bucket keyed by its UTC start date.
  public struct Bucket: Equatable, Sendable {
    public var startDate: String
    public var tokens: Double
    public var source: JSONValue
    public var fromRouterFallback: Bool

    public init(startDate: String, tokens: Double, source: JSONValue = .null, fromRouterFallback: Bool = false) {
      self.startDate = startDate
      self.tokens = tokens
      self.source = source
      self.fromRouterFallback = fromRouterFallback
    }
  }

  static func utcDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  /// The last `days` UTC days, oldest first, filling gaps with zero. The
  /// window is walked in UTC because every bucket key is a UTC day.
  public static func bucketRange(_ buckets: [JSONValue], days: Int, now: Date = Date()) -> [Bucket] {
    var index: [String: JSONValue] = [:]
    for bucket in buckets {
      if let key = bucket["startDate"]?.string { index[key] = bucket }
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let anchor = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
    return (0..<max(0, days)).map { offset in
      let date = calendar.date(byAdding: .day, value: -(days - offset - 1), to: anchor) ?? anchor
      let key = utcDayKey(date)
      if let existing = index[key] {
        return Bucket(startDate: key, tokens: existing["tokens"]?.double ?? 0, source: existing)
      }
      return Bucket(startDate: key, tokens: 0)
    }
  }

  /// OpenAI's account stream is authoritative for any date it contains; the
  /// router's own OpenAI meter only fills dates the account stream lacks.
  public static func accountBucketsWithRouterFallback(account: [JSONValue], router: [JSONValue]) -> [Bucket] {
    var merged: [String: Bucket] = [:]
    for bucket in router {
      guard let key = bucket["startDate"]?.string else { continue }
      merged[key] = Bucket(startDate: key, tokens: bucket["tokens"]?.double ?? 0, source: bucket, fromRouterFallback: true)
    }
    for bucket in account {
      guard let key = bucket["startDate"]?.string else { continue }
      merged[key] = Bucket(startDate: key, tokens: bucket["tokens"]?.double ?? 0, source: bucket, fromRouterFallback: false)
    }
    return merged.values.sorted { $0.startDate < $1.startDate }
  }
}
