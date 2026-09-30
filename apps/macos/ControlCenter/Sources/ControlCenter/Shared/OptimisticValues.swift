import ControlCenterCore
import SwiftUI

/// Switches that respond immediately and settle to the router's answer,
/// ported from `useOptimisticValues.ts`.
///
/// A page owns one of these as `@StateObject`, reads `value(key, fallback:)`
/// with the authoritative value from the snapshot as the fallback, and calls
/// `reconcile(with:)` whenever that snapshot changes. Mutations reach the
/// router in click order, and a failed one rolls its keys back unless a
/// newer click has superseded them.
@MainActor
final class OptimisticValues<Value: Equatable>: ObservableObject {
  @Published private(set) var overrides: [String: Value] = [:]
  private var revisions: [String: Int] = [:]
  private var queue: Task<Void, Never>?

  func value(_ key: String, fallback: Value) -> Value {
    overrides[key] ?? fallback
  }

  /// Drops every override the router now agrees with.
  func reconcile(with authoritative: [String: Value]) {
    let settled = overrides.filter { key, optimistic in authoritative[key] == optimistic }.map(\.key)
    guard !settled.isEmpty else { return }
    for key in settled { overrides.removeValue(forKey: key) }
  }

  func mutate(
    _ key: String,
    to next: Value,
    label: String,
    model: AppModel,
    action: @escaping (RouterControl) async throws -> JSONValue
  ) {
    mutateMany([(key, next)], label: label, model: model, action: action)
  }

  func mutateMany(
    _ changes: [(String, Value)],
    label: String,
    model: AppModel,
    action: @escaping (RouterControl) async throws -> JSONValue
  ) {
    guard !changes.isEmpty else { return }
    var mutationRevisions: [String: Int] = [:]
    for (key, next) in changes {
      let revision = (revisions[key] ?? 0) + 1
      revisions[key] = revision
      mutationRevisions[key] = revision
      overrides[key] = next
    }
    let previous = queue
    let api = model.api
    queue = Task { [weak self, weak model] in
      await previous?.value
      guard let model else { return }
      var saved = false
      await model.runAction(label) {
        let result = try await action(api)
        saved = true
        return result
      }
      guard !saved, let self else { return }
      for (key, revision) in mutationRevisions where self.revisions[key] == revision {
        self.overrides.removeValue(forKey: key)
      }
    }
  }
}
