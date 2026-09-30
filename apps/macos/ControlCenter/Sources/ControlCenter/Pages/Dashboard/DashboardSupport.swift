import ControlCenterCore
import Foundation

// Small helpers the Dashboard page shares. The renderer reads router JSON with
// JavaScript's coercion rules (`Number(value)`, `??`, `||`), and several
// figures on the page depend on exactly where those rules differ from Swift's,
// so they are reproduced here rather than approximated at each call site.

enum DashboardJS {
  static let hourMs: Double = 3_600_000
  static let dayMs: Double = 86_400_000

  /// `Number(value)`: NaN when the value does not convert.
  static func number(_ value: JSONValue?) -> Double {
    guard let value = value else { return Double.nan }
    switch value {
    case .null:
      return 0
    case .bool(let flag):
      return flag ? 1 : 0
    case .number(let parsed):
      return parsed
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return 0 }
      return Double(trimmed) ?? Double.nan
    case .array, .object:
      return Double.nan
    }
  }

  /// `optionalNumber` in DashboardPage.tsx: a finite, non-negative number.
  static func optionalNumber(_ value: JSONValue?) -> Double? {
    let parsed = number(value)
    return parsed.isFinite && parsed >= 0 ? parsed : nil
  }

  /// `Number(value) || 0`.
  static func numberOrZero(_ value: JSONValue?) -> Double {
    let parsed = number(value)
    return parsed.isNaN ? 0 : parsed
  }

  /// `Number.isFinite(Number(value))`.
  static func isFiniteNumber(_ value: JSONValue?) -> Bool {
    number(value).isFinite
  }

  /// JavaScript `??` treats `undefined` and `null` alike; so does this.
  static func nullish(_ value: JSONValue?) -> JSONValue? {
    guard let value = value, !value.isNull else { return nil }
    return value
  }

  /// A string that is truthy in JavaScript (non-empty), else nil.
  static func nonEmpty(_ value: JSONValue?) -> String? {
    guard let text = value?.string, !text.isEmpty else { return nil }
    return text
  }

  /// `Int(value)` that cannot trap: non-finite reads as 0 and huge values
  /// clamp, since router JSON can carry numeric strings such as "Infinity".
  static func safeInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(min(max(value, -1e15), 1e15))
  }

  /// `String(number)` for the values this page prints: integers without a
  /// fractional part.
  static func string(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}

/// A dictionary that remembers insertion order, like a JavaScript `Map`, so
/// ties in the breakdown sort resolve the way they do in the renderer.
struct DashboardOrderedMap<Value> {
  private(set) var keys: [String] = []
  private var storage: [String: Value] = [:]

  subscript(key: String) -> Value? {
    get { storage[key] }
    set {
      if let newValue = newValue {
        if storage[key] == nil { keys.append(key) }
        storage[key] = newValue
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  var values: [Value] {
    keys.compactMap { storage[$0] }
  }

  var count: Int { keys.count }
  var isEmpty: Bool { keys.isEmpty }
}

enum DashboardTime {
  private static let withFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let dayOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  /// Every usage day key is a UTC day, so the page walks days in UTC.
  static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current
    return calendar
  }()

  static func nowMillis() -> Double {
    (Date().timeIntervalSince1970 * 1_000).rounded(.down)
  }

  /// `Date.parse` for the ISO timestamps the router writes. Nil when the text
  /// is not one (`NaN` in the renderer).
  static func millis(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if let date = withFraction.date(from: trimmed) { return (date.timeIntervalSince1970 * 1_000).rounded() }
    if let date = plain.date(from: trimmed) { return (date.timeIntervalSince1970 * 1_000).rounded() }
    if let date = dayOnly.date(from: trimmed) { return (date.timeIntervalSince1970 * 1_000).rounded() }
    return nil
  }

  static func date(millis: Double) -> Date {
    Date(timeIntervalSince1970: millis / 1_000)
  }

  /// `YYYY-MM-DD` for the UTC day containing `millis`.
  static func dayKey(_ millis: Double) -> String {
    let parts = utcCalendar.dateComponents([.year, .month, .day], from: date(millis: millis))
    return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 0 for Sunday, like `getUTCDay()`. The epoch fell on a Thursday.
  static func weekday(_ millis: Double) -> Int {
    let days = Int((millis / DashboardJS.dayMs).rounded(.down))
    return (((days + 4) % 7) + 7) % 7
  }

  /// Milliseconds at the start of the local hour containing `millis`
  /// (`setMinutes(0, 0, 0)`).
  static func localHourStart(_ millis: Double) -> Double {
    let value = date(millis: millis)
    let start = Calendar.current.dateInterval(of: .hour, for: value)?.start ?? value
    return (start.timeIntervalSince1970 * 1_000).rounded()
  }

  /// `^(\d{4})-(\d{2})-(\d{2})` applied to a usage bucket's `startDate`.
  static func normalizedDateKey(_ value: JSONValue?) -> String? {
    guard let text = value?.string else { return nil }
    let characters = Array(text.prefix(10))
    guard characters.count == 10 else { return nil }
    func isDigit(_ character: Character) -> Bool {
      return character >= "0" && character <= "9"
    }
    for (index, character) in characters.enumerated() {
      if index == 4 || index == 7 {
        if character != "-" { return nil }
      } else if !isDigit(character) {
        return nil
      }
    }
    return String(characters)
  }
}

enum DashboardFormatters {
  /// A date formatter for a localized template such as `MMMd`.
  static func make(locale: Locale, template: String, utc: Bool) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    if utc { formatter.timeZone = DashboardTime.utcCalendar.timeZone }
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }
}

/// One entry of `target.usageEvents`, read once so the many passes over the
/// event stream do not each re-parse JSON. Fields keep their raw JSON so the
/// JavaScript coercions above apply to them exactly as they do in the
/// renderer.
struct DashboardEvent: Equatable {
  var at: String
  var atMillis: Double?
  var model: String?
  var provider: String?
  var status: Double?
  var durationMs: JSONValue?
  var firstTokenMs: JSONValue?
  var inputTokens: JSONValue?
  var billedInputTokens: JSONValue?
  var cachedInputTokens: JSONValue?
  var outputTokens: JSONValue?
  var billedOutputTokens: JSONValue?
  var reasoningTokens: JSONValue?
  var totalTokens: JSONValue?
  var reasoningStreamed: Bool?
  /// Any of the flags that make a speed sample untrustworthy: a retry, an
  /// aborted stream, an empty or repaired completion.
  var speedDisqualified: Bool

  init(_ json: JSONValue) {
    let text = json["at"]?.string ?? ""
    self.at = text
    self.atMillis = DashboardTime.millis(text)
    self.model = DashboardJS.nonEmpty(json["model"])
    self.provider = DashboardJS.nonEmpty(json["provider"])
    self.status = DashboardJS.nullish(json["status"])?.double
    self.durationMs = json["durationMs"]
    self.firstTokenMs = json["firstTokenMs"]
    self.inputTokens = json["inputTokens"]
    self.billedInputTokens = json["billedInputTokens"]
    self.cachedInputTokens = json["cachedInputTokens"]
    self.outputTokens = json["outputTokens"]
    self.billedOutputTokens = json["billedOutputTokens"]
    self.reasoningTokens = json["reasoningTokens"]
    self.totalTokens = json["totalTokens"]
    self.reasoningStreamed = json["reasoningStreamed"]?.bool
    let flags: [String] = [
      "retries", "streamAborted", "emptyCompletion", "emptyCompletionRetried",
      "progressOnlyRetried", "emptyCompletionUnrepairable",
    ]
    var disqualified = false
    for flag in flags where json[flag].truthy {
      disqualified = true
    }
    self.speedDisqualified = disqualified
  }
}
