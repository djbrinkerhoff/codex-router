import ControlCenterCore
import SwiftUI

/// Local runtime, MLX installer, Ollama models, and image reading. Ported
/// from `LocalPage.tsx`; the sections live under `Pages/Local/`.
struct LocalPage: View {
  @EnvironmentObject private var model: AppModel
  @State private var installRef = ""
  @State private var forceInstall = false
  @State private var pendingRemoval: String?
  @State private var catalogQuery = ""
  @State private var expandedFamilies: Set<String> = []
  @StateObject private var localToggles = OptimisticValues<Bool>()
  @StateObject private var visionToggles = OptimisticValues<Bool>()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: model.t("local.eyebrow"),
        title: model.t("local.title"),
        description: model.t("local.description"),
        onRefresh: { Task { await model.refreshAll() } }
      )
      if model.target == nil {
        unavailable
      } else {
        content(LocalDerived(target: model.target, operation: model.operation))
      }
    }
    .onChange(of: model.snapshot) { _ in reconcile() }
    .onChange(of: model.operation) { _ in reconcile() }
    .alert(
      model.t("local.remove.title"),
      isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      presenting: pendingRemoval
    ) { tag in
      Button(model.t("local.remove.cancel"), role: .cancel) { pendingRemoval = nil }
      Button(model.t("local.remove.confirm"), role: .destructive) { confirmRemoval(tag) }
    } message: { tag in
      Text(removalMessage(tag))
    }
  }

  // MARK: Unavailable

  @ViewBuilder
  private var unavailable: some View {
    if !model.isReady(.snapshot) {
      PanelSkeleton(label: model.t("local.loadingRuntime"), count: 5)
        .panelStyle(padding: 14)
    } else {
      EmptyStateView(
        systemImage: "magnifyingglass",
        title: model.t("local.unavailableTitle"),
        message: model.t("local.unavailableBody")
      )
    }
  }

  // MARK: Content

  private func content(_ d: LocalDerived) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      StatStrip(items: stats(d))
      InlineNotice(
        tone: d.runtimeRunning ? .success : .warning,
        title: d.runtimeRunning ? model.t("local.ollama.ready") : model.t("local.ollama.notRunning"),
        message: d.local?["machine"]?.text ?? model.t("local.ollama.unmeasured")
      )
      LocalMlxSection(d: d)
      LocalInstalledSection(
        d: d,
        isEnabled: { item in isModelEnabled(item, d) },
        onToggle: { item, next in toggleModel(item, next) },
        onRemove: { tag in pendingRemoval = tag }
      )
      LocalInstallSection(
        d: d,
        installRef: $installRef,
        forceInstall: $forceInstall,
        catalogQuery: $catalogQuery,
        expandedFamilies: $expandedFamilies,
        onInstall: installLocal
      )
      LocalVisionSection(
        d: d,
        visionEnabled: visionToggles.value("vision", fallback: d.bridge?["enabled"]?.bool == true),
        onToggleVision: { next in toggleVision(next) }
      )
    }
  }

  private func stats(_ d: LocalDerived) -> [StatItem] {
    let t = model.t
    let runtime = d.local?["runtime"]
    let version = runtime?["version"]?.text
    let visionOn = visionToggles.value("vision", fallback: d.bridge?["enabled"]?.bool == true)
    let enabledCount = d.installed.filter { isModelEnabled($0, d) }.count
    let reader: String
    if d.bridge?["engine"]?.string == "local" {
      reader = t("local.stats.local")
    } else {
      reader = d.bridge?["resolvedEngineName"]?.text ?? t("local.stats.automatic")
    }
    return [
      StatItem(
        label: t("local.stats.runtime"),
        value: d.runtimeRunning ? t("local.stats.online") : t("local.stats.offline"),
        detail: version.map { t("local.stats.ollamaVersion", ["version": $0]) } ?? "Ollama"
      ),
      StatItem(
        label: t("local.stats.installed"),
        value: String(d.installedCount),
        detail: t("local.stats.inCodex", ["count": enabledCount])
      ),
      StatItem(
        label: t("local.stats.storage"),
        value: Format.bytesGb(d.local?["totalGb"]?.double, t),
        detail: runtime?["modelsPath"]?.text ?? t("local.stats.ollamaManaged")
      ),
      StatItem(
        label: t("local.stats.imageReader"),
        value: reader,
        detail: visionOn ? t("local.stats.bridgeEnabled") : t("local.stats.bridgeDisabled")
      ),
    ]
  }

  // MARK: Optimistic switches

  private func authoritativeEnabled(_ item: JSONValue, _ d: LocalDerived) -> Bool {
    d.enabledTags.contains(item["tag"]?.string ?? "") || item["enabled"]?.bool == true
  }

  private func isModelEnabled(_ item: JSONValue, _ d: LocalDerived) -> Bool {
    localToggles.value(item["tag"]?.string ?? "", fallback: authoritativeEnabled(item, d))
  }

  private func toggleModel(_ item: JSONValue, _ next: Bool) {
    guard let tag = item["tag"]?.string else { return }
    let label = model.t(next ? "local.action.enable" : "local.action.disable", ["tag": tag])
    localToggles.mutate(tag, to: next, label: label, model: model) { api in
      try await api.setLocalModelEnabled(tag, next)
    }
  }

  private func toggleVision(_ next: Bool) {
    let label = model.t(next ? "local.action.enableVision" : "local.action.disableVision")
    visionToggles.mutate("vision", to: next, label: label, model: model) { api in
      try await api.setVisionBridgeEnabled(next)
    }
  }

  /// Drops switch overrides the router now agrees with, as the renderer's
  /// hook does whenever its authoritative map changes.
  private func reconcile() {
    let d = LocalDerived(target: model.target, operation: model.operation)
    var states: [String: Bool] = [:]
    var enabledSet: Set<String>?
    if let list = d.local?["enabled"]?.array { enabledSet = Set(list.compactMap(\.string)) }
    for item in d.installed {
      guard let tag = item["tag"]?.string else { continue }
      states[tag] = (enabledSet?.contains(tag) ?? false) || item["enabled"]?.bool == true
    }
    localToggles.reconcile(with: states)
    visionToggles.reconcile(with: ["vision": d.bridge?["enabled"]?.bool == true])
  }

  // MARK: Actions

  private func installLocal() {
    let ref = installRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ref.isEmpty else { return }
    installRef = ""
    let force = forceInstall
    LocalActions.run(model, model.t("local.action.install", ["model": ref]), startsDownload: true) { api in
      try await api.installLocalModel(ref, force: force)
    }
  }

  private func removalMessage(_ tag: String) -> String {
    let body = "\(model.t("local.remove.bodyPrefix")) \(tag)\(model.t("local.remove.bodySuffix"))"
    return "\(model.t("local.remove.description"))\n\(body)"
  }

  private func confirmRemoval(_ tag: String) {
    pendingRemoval = nil
    LocalActions.run(model, model.t("local.action.remove", ["tag": tag])) { api in
      try await api.uninstallLocalModel(tag)
    }
  }
}
