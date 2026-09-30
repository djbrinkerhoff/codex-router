import ControlCenterCore
import SwiftUI

// Pure helpers for the Context Manager page, ported from the top and bottom of
// `ContextPage.tsx`.

/// One indexed session with a key that is unique within the list.
struct ContextSessionItem: Identifiable {
  let id: String
  let value: JSONValue
}

/// A model the Codex terminal resume can switch to.
struct ContextModelChoice: Identifiable {
  let slug: String
  let name: String
  var id: String { slug }
}

/// The figures in the stat strip.
struct ContextStats {
  let workspaceCount: Int
  let modelCount: Int
  let inputTokens: Double
  let cachedTokens: Double

  var cachePercent: Int {
    inputTokens > 0 ? Int((cachedTokens / inputTokens * 100).rounded()) : 0
  }

  init(sessions: [JSONValue]) {
    var workspaces = Set<String>()
    var models = Set<String>()
    var input = 0.0
    var cached = 0.0
    for session in sessions {
      if let workspace = session["workspace"]?.string, !workspace.isEmpty {
        workspaces.insert(workspace)
      }
      if let history = session["modelHistory"]?.array, !history.isEmpty {
        for entry in history.compactMap(\.string) { models.insert(entry) }
      } else if let model = session["model"]?.string, !model.isEmpty {
        models.insert(model)
      }
      input += session["inputTokens"]?.double ?? 0
      cached += session["cachedInputTokens"]?.double ?? 0
    }
    workspaceCount = workspaces.count
    modelCount = models.count
    inputTokens = input
    cachedTokens = cached
  }
}

enum ContextSupport {
  static let harnessFilters = ["all", "cursor", "dsh", "codex"]

  static func harnessName(_ harnessId: String) -> String {
    if harnessId == "codex" { return "Codex" }
    if harnessId == "dsh" { return "DeepSeek Harness" }
    return "Cursor"
  }

  /// "waiting_for_user" -> "Waiting For User".
  static func readableStatus(_ status: String) -> String {
    var result = ""
    var previousIsWord = false
    for character in status.replacingOccurrences(of: "_", with: " ") {
      let isWord = character.isLetter || character.isNumber
      result += (isWord && !previousIsWord) ? character.uppercased() : String(character)
      previousIsWord = isWord
    }
    return result
  }

  static func filter(
    _ sessions: [JSONValue],
    search: String,
    harness: String,
    showArchived: Bool
  ) -> [JSONValue] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return sessions.filter { session in
      if !showArchived && session["archived"].truthy { return false }
      if harness != "all" && session["harnessId"]?.string != harness { return false }
      if needle.isEmpty { return true }
      let title = session["title"]?.string ?? ""
      let model = session["model"]?.string ?? ""
      let workspace = session["workspace"]?.string ?? ""
      let harnessId = session["harnessId"]?.string ?? ""
      return "\(title) \(model) \(workspace) \(harnessId)".lowercased().contains(needle)
    }
  }

  /// Keys are `harnessId:id`; a repeated pair gets a suffix so the list never
  /// holds two rows with one identity.
  static func items(_ sessions: [JSONValue]) -> [ContextSessionItem] {
    var seen: [String: Int] = [:]
    return sessions.map { session in
      let base = "\(session["harnessId"]?.string ?? ""):\(session["id"]?.string ?? "")"
      let count = seen[base, default: 0]
      seen[base] = count + 1
      return ContextSessionItem(id: count == 0 ? base : "\(base)#\(count)", value: session)
    }
  }

  static func tone(for session: JSONValue) -> Tone {
    if session["archived"].truthy { return .neutral }
    switch session["status"]?.string {
    case "failed", "permission_denied":
      return .danger
    case "processing", "waiting_for_user", "ask_permission":
      return .accent
    default:
      return .success
    }
  }
}
