import Foundation

/// A display language, ported from `apps/control-center/src/i18n.ts`.
public struct LanguageOption: Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let locale: String
  public let rtl: Bool
}

/// The string catalogs generated from the renderer's locale modules by
/// `scripts/generate-strings.mjs`. Loaded once; immutable afterwards.
public final class StringCatalogs: @unchecked Sendable {
  public static let shared = StringCatalogs(directory: StringCatalogs.defaultDirectory())

  public let languages: [LanguageOption]
  let catalogs: [String: [String: String]]
  let backendKeys: [String: String]
  let backendPatterns: [(regex: NSRegularExpression, groups: [String], key: String)]

  /// The packaged app copies the catalogs into its own Resources; a
  /// development build and the tests read the SwiftPM resource bundle.
  static func defaultDirectory() -> URL? {
    if let packaged = Bundle.main.resourceURL?.appendingPathComponent("Strings", isDirectory: true),
      FileManager.default.fileExists(atPath: packaged.appendingPathComponent("en.json").path)
    {
      return packaged
    }
    return Bundle.module.resourceURL?.appendingPathComponent("Strings", isDirectory: true)
  }

  public init(directory: URL?) {
    func load(_ name: String) -> JSONValue? {
      guard let directory,
        let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path)
      else { return nil }
      return try? JSONValue.parse(data)
    }
    let languageList = load("languages.json")?.items.compactMap { item -> LanguageOption? in
      guard let id = item["id"]?.string, let label = item["label"]?.string, let locale = item["locale"]?.string else {
        return nil
      }
      return LanguageOption(id: id, label: label, locale: locale, rtl: item["rtl"]?.bool ?? false)
    } ?? []
    languages = languageList.isEmpty
      ? [LanguageOption(id: "en", label: "English", locale: "en-US", rtl: false)]
      : languageList
    var loaded: [String: [String: String]] = [:]
    for option in languages {
      guard let object = load("\(option.id).json")?.object else { continue }
      loaded[option.id] = object.compactMapValues(\.string)
    }
    catalogs = loaded
    let backend = load("backend.json")
    backendKeys = backend?["keys"]?.object?.compactMapValues(\.string) ?? [:]
    let groupName = try? NSRegularExpression(pattern: "\\(\\?<([A-Za-z_][A-Za-z0-9_]*)>")
    backendPatterns = backend?["patterns"]?.items.compactMap { item -> (regex: NSRegularExpression, groups: [String], key: String)? in
      guard let source = item["source"]?.string, let key = item["key"]?.string,
        let regex = try? NSRegularExpression(pattern: source)
      else { return nil }
      let range = NSRange(source.startIndex..<source.endIndex, in: source)
      let groups = groupName?.matches(in: source, range: range).compactMap { match -> String? in
        guard let captured = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[captured])
      } ?? []
      return (regex: regex, groups: groups, key: key)
    } ?? []
  }

  public func isLanguage(_ id: String) -> Bool {
    languages.contains { $0.id == id }
  }

  public func option(_ id: String) -> LanguageOption {
    languages.first { $0.id == id } ?? languages[0]
  }

  /// Script beats region: zh-Hans-TW is Simplified, zh-Hant-CN / zh-HK /
  /// zh-MO are Traditional. Anything unrecognized is English.
  public func resolveLanguage(_ value: String?) -> String {
    guard let value, value.count <= 128 else { return "en" }
    let trimmed = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
    guard !trimmed.isEmpty else { return "en" }
    let parts = trimmed.split(separator: "-").map(String.init)
    let language = parts[0].lowercased()
    var script: String?
    var region: String?
    for part in parts.dropFirst() {
      if part.count == 4, script == nil, region == nil {
        script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
      } else if (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
        if region == nil { region = part.uppercased() }
      }
    }
    if language == "zh" {
      if script == "Hans" { return "zh-CN" }
      if script == "Hant" { return "zh-TW" }
      if script != nil { return "en" }
      return ["TW", "HK", "MO"].contains(region ?? "") ? "zh-TW" : "zh-CN"
    }
    return isLanguage(language) ? language : "en"
  }

  func template(_ key: String, language: String) -> String {
    if let value = catalogs[language]?[key] { return value }
    if let value = catalogs["en"]?[key] { return value }
    return key
  }
}

/// Translates semantic message ids exactly as `translate()` in `i18n.ts` does:
/// the chosen catalog, then English, then the id itself; `{name}` is replaced
/// in one pass and only by a supplied value.
public struct Translator: Sendable {
  public let language: String
  let catalogs: StringCatalogs

  public init(language: String, catalogs: StringCatalogs = .shared) {
    self.catalogs = catalogs
    self.language = catalogs.isLanguage(language) ? language : "en"
  }

  public var option: LanguageOption { catalogs.option(language) }
  public var locale: Locale { Locale(identifier: option.locale) }
  public var isChinese: Bool { language == "zh-CN" || language == "zh-TW" }

  public func callAsFunction(_ key: String, _ values: [String: CustomStringConvertible] = [:]) -> String {
    Self.interpolate(catalogs.template(key, language: language), values)
  }

  static func interpolate(_ template: String, _ values: [String: CustomStringConvertible]) -> String {
    guard template.contains("{") else { return template }
    var result = ""
    var index = template.startIndex
    while index < template.endIndex {
      let character = template[index]
      if character == "{",
        let close = template[index...].firstIndex(of: "}"),
        close > template.index(after: index)
      {
        let name = template[template.index(after: index)..<close]
        if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
          if let value = values[String(name)] {
            result += value.description
          } else {
            result += template[index...close]
          }
          index = template.index(after: close)
          continue
        }
      }
      result.append(character)
      index = template.index(after: index)
    }
    return result
  }

  /// Localizes recognized backend-owned display copy (`backend-text.ts`).
  /// Diagnostics, ids, paths, and user content pass through untouched, and
  /// only the Chinese catalogs translate backend wording at all.
  public func backend(_ source: String?) -> String {
    guard let value = source, !value.isEmpty, isChinese else { return source ?? "" }
    if let key = catalogs.backendKeys[value] { return self(key) }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    for pattern in catalogs.backendPatterns {
      guard let match = pattern.regex.firstMatch(in: value, range: range) else { continue }
      var captured: [String: CustomStringConvertible] = [:]
      for name in pattern.groups {
        if let groupRange = Range(match.range(withName: name), in: value) {
          captured[name] = String(value[groupRange])
        }
      }
      return self(pattern.key, captured)
    }
    return value
  }
}
