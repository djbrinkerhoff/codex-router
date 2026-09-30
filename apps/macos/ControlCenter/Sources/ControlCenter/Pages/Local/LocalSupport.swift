import ControlCenterCore
import SwiftUI

// Derived values and helpers for the Local page, ported from the top of
// `LocalPage.tsx` and its module-level functions. Everything here is pure so a
// page render is one `LocalDerived` and the subviews only lay it out.

/// One image-reader engine offered by the vision bridge.
struct LocalEngine: Identifiable, Equatable {
  enum Source { case chatgpt, provider }

  let slug: String
  let displayName: String
  let group: Source
  let efforts: [String]

  var id: String { "\(group)-\(slug)" }
}

/// One Ollama family in the catalog browser.
struct LocalCatalogFamily: Identifiable {
  let id: String
  var displayName: String
  var models: [JSONValue]
  var researchStatus: String?
  var researchCapabilities: [String]
  var researchNote: String?
}

/// Everything the page computes from `target.modelSettings` before it renders.
struct LocalDerived {
  let local: JSONValue?
  let bridge: JSONValue?
  let mlx: JSONValue?
  let mlxStatus: String
  let mlxActive: Bool
  let mlxPublished: Bool
  let mlxReady: Bool
  let mlxSupported: Bool
  let ollamaMutationActive: Bool
  let installed: [JSONValue]
  let installedCount: Int
  let enabledTags: [String]
  let localReaders: [JSONValue]
  let readerDownloadActive: Bool
  let engines: [LocalEngine]
  let selectedEngine: String
  let effortOptions: [String]
  let catalogModels: [JSONValue]
  let quickPicks: [JSONValue]
  let knownFamilies: [JSONValue]

  var runtimeRunning: Bool { (local?["runtime"]?["running"]).truthy }
  var runtimeInstalled: Bool { (local?["runtime"]?["installed"]).truthy }

  init(target: JSONValue?, operation: OperationEvent?) {
    let settings = target?["modelSettings"]
    let local = settings?["localModels"]
    let bridge = settings?["visionBridge"]
    let mlx = local?["mlx"]
    self.local = local
    self.bridge = bridge
    self.mlx = mlx

    let status = mlx?["operation"]?["status"]?.text ?? "idle"
    let active = LocalSupport.activeMlxStatuses.contains(status)
    let published = mlx?["runtime"]?["published"]?.bool == true
    self.mlxStatus = status
    self.mlxActive = active
    self.mlxPublished = published
    self.mlxReady = published && mlx?["runtime"]?["served"]?.bool == true
    self.mlxSupported = mlx?["host"]?["supported"]?.bool != false

    let action = operation?.action ?? ""
    let downloadStatus = local?["download"]?["status"]?.string ?? ""
    let operationBusy = operation?.status == .started && (
      action == "installLocalModel"
        || action == "uninstallLocalModel"
        || action.hasPrefix("Install ")
        || action.hasPrefix("Remove ")
    )
    self.ollamaMutationActive = ["downloading", "uninstalling"].contains(downloadStatus) || operationBusy

    let installedModels = (local?["models"]?.items ?? []).filter { $0["installed"]?.bool != false }
    self.installed = installedModels

    var count = installedModels.count
    switch local?["installed"] {
    case .some(.number(let value)):
      if value.isFinite, abs(value) < 1e15 { count = Int(value) }
    case .some(.array(let values)):
      count = values.count
    default:
      break
    }
    self.installedCount = count

    if let enabled = local?["enabled"]?.array {
      self.enabledTags = enabled.compactMap(\.string)
    } else {
      self.enabledTags = installedModels
        .filter { $0["enabled"]?.bool == true }
        .compactMap { $0["tag"]?.string }
    }

    if let readers = bridge?["localModels"]?.array {
      self.localReaders = readers
    } else if let readers = local?["availableVision"]?.array {
      self.localReaders = readers
    } else {
      self.localReaders = []
    }
    self.readerDownloadActive = bridge?["download"]?["status"]?.string == "downloading"

    let allEngines = LocalSupport.engines(bridge?["nativeEngines"], group: .chatgpt)
      + LocalSupport.engines(bridge?["paidEngines"], group: .provider)
    self.engines = allEngines
    let selected = bridge?["engine"]?.text ?? "auto"
    self.selectedEngine = selected
    let meta = allEngines.first { $0.slug == selected }
    if let efforts = meta?.efforts, !efforts.isEmpty {
      self.effortOptions = efforts
    } else {
      self.effortOptions = bridge?["availableEfforts"]?.strings ?? []
    }

    self.catalogModels = local?["availableExplore"]?.items ?? []
    let picks = (local?["available"]?.array ?? []) + (local?["availableVision"]?.items ?? [])
    self.quickPicks = Array(picks.prefix(8))
    self.knownFamilies = local?["families"]?.items ?? []
  }
}

enum LocalSupport {
  static let activeMlxStatuses: Set<String> = [
    "preparing", "downloading", "loading", "starting-server", "verifying", "publishing",
  ]

  static func engines(_ list: JSONValue?, group: LocalEngine.Source) -> [LocalEngine] {
    (list?.items ?? []).compactMap { item -> LocalEngine? in
      guard let slug = item["slug"]?.string else { return nil }
      return LocalEngine(
        slug: slug,
        displayName: item["displayName"]?.string ?? slug,
        group: group,
        efforts: item["efforts"]?.strings ?? []
      )
    }
  }

  /// The first non-empty string, mirroring JavaScript's `a || b`.
  static func or(_ first: String, _ second: String) -> String {
    first.isEmpty ? second : first
  }

  static func stageLabel(_ status: String, _ t: Translator) -> String {
    switch status {
    case "preparing": return t("local.mlx.stage.preparing")
    case "downloading": return t("local.mlx.stage.downloading")
    case "loading": return t("local.mlx.stage.loading")
    case "starting-server": return t("local.mlx.stage.startingServer")
    case "verifying": return t("local.mlx.stage.verifying")
    case "publishing": return t("local.mlx.stage.publishing")
    default: return t("local.mlx.stage.default")
    }
  }

  // MARK: Catalog

  static func modelName(_ model: JSONValue) -> String {
    model["displayName"]?.text ?? model["label"]?.text ?? model["tag"]?.string ?? ""
  }

  static func brand(for model: JSONValue) -> ProviderBrand {
    ProviderBranding.forLocalModel(
      tag: model["tag"]?.string ?? "",
      family: model["family"]?.string,
      displayName: model["displayName"]?.string
    )
  }

  static func fits(_ model: JSONValue) -> Bool {
    model["downloadable"]?.bool != false
      && model["fit"]?.string != "too-large"
      && model["diskFit"]?.string != "too-large"
  }

  static func modelSort(_ left: JSONValue, _ right: JSONValue) -> Bool {
    let leftLatest = left["variant"]?.string == "latest"
    let rightLatest = right["variant"]?.string == "latest"
    if leftLatest != rightLatest { return leftLatest }
    let leftFit = fits(left)
    let rightFit = fits(right)
    if leftFit != rightFit { return leftFit }
    let leftTag = left["tag"]?.string ?? ""
    let rightTag = right["tag"]?.string ?? ""
    return leftTag.localizedCompare(rightTag) == .orderedAscending
  }

  static func groupCatalog(_ models: [JSONValue], families known: [JSONValue], query: String) -> [LocalCatalogFamily] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var order: [String] = []
    var groups: [String: LocalCatalogFamily] = [:]
    for model in models {
      let tag = model["tag"]?.string ?? ""
      let family = model["family"]?.text
      let tagHead = tag.components(separatedBy: ":").first ?? ""
      let familyId = family ?? (tagHead.isEmpty ? tag : tagHead)
      let searchable = "\(tag) \(model["displayName"]?.string ?? "") \(model["family"]?.string ?? "")".lowercased()
      if !needle.isEmpty && !searchable.contains(needle) { continue }
      let match = known.first { $0["family"]?.string == familyId }
      let baseName = match?["displayName"]?.text ?? model["displayName"]?.text ?? familyId
      let displayName = baseName.components(separatedBy: " · ").first ?? baseName
      var current: LocalCatalogFamily
      if let existing = groups[familyId] {
        current = existing
      } else {
        order.append(familyId)
        current = LocalCatalogFamily(
          id: familyId,
          displayName: displayName,
          models: [],
          researchStatus: model["researchStatus"]?.text,
          researchCapabilities: model["researchCapabilities"]?.strings ?? [],
          researchNote: model["researchNote"]?.text
        )
      }
      current.models.append(model)
      if current.researchStatus == nil, let status = model["researchStatus"]?.text {
        current.researchStatus = status
      }
      if current.researchCapabilities.isEmpty, let capabilities = model["researchCapabilities"]?.strings, !capabilities.isEmpty {
        current.researchCapabilities = capabilities
      }
      if current.researchNote == nil, let note = model["researchNote"]?.text {
        current.researchNote = note
      }
      groups[familyId] = current
    }
    var result: [LocalCatalogFamily] = []
    for id in order {
      guard var family = groups[id] else { continue }
      family.models.sort(by: modelSort)
      result.append(family)
    }
    result.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    return result
  }

  static func visibleTagCount(_ families: [LocalCatalogFamily]) -> Int {
    families.reduce(0) { $0 + $1.models.count }
  }

  static func familySummary(_ models: [JSONValue], _ t: Translator) -> String {
    let fit = models.filter(fits).count
    let cloud = models.filter { $0["downloadable"]?.bool == false }.count
    if cloud == models.count { return t("local.family.cloudOnly") }
    if fit == models.count { return t("local.family.allFit") }
    if fit > 0 && cloud > 0 { return t("local.family.fitCloud", ["fit": fit, "cloud": cloud]) }
    if fit > 0 { return t("local.family.fit", ["fit": fit]) }
    if cloud > 0 { return t("local.family.cloud", ["cloud": cloud]) }
    return t("local.family.noFit")
  }
}

/// Runs one router action with the shared operation feedback, then makes sure
/// the four-second download poll matches what the refreshed snapshot reports.
@MainActor
enum LocalActions {
  static func run(
    _ model: AppModel,
    _ label: String,
    startsDownload: Bool = false,
    _ action: @escaping (RouterControl) async throws -> JSONValue
  ) {
    let api = model.api
    Task {
      await model.runAction(label) { try await action(api) }
      if startsDownload { model.updateDownloadPolling() }
    }
  }
}

/// A progress bar with a title, a percentage, and one line of detail
/// (`DownloadProgress`).
struct LocalDownloadProgress: View {
  @EnvironmentObject private var model: AppModel
  var tag: String?
  var percent: Double?
  var detail: String?
  var indeterminate = false

  var body: some View {
    let title = LocalSupport.or(tag ?? "", model.t("local.progress.defaultTag"))
    let value = min(100, max(0, percent ?? 0))
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Text(indeterminate ? model.t("local.progress.working") : "\(Int((percent ?? 0).rounded()))%")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if indeterminate {
        ProgressView().progressViewStyle(.linear)
      } else {
        ProgressView(value: value, total: 100).progressViewStyle(.linear)
      }
      Text(LocalSupport.or(detail ?? "", model.t("local.progress.preparing")))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    .accessibilityElement(children: .combine)
  }
}

/// An on/off switch with no visible label, as the renderer's `Toggle` drew it.
struct LocalSwitch: View {
  let isOn: Bool
  let label: String
  var disabled = false
  /// The tooltip; the accessibility label when absent.
  var hint: String?
  let onChange: (Bool) -> Void

  var body: some View {
    Toggle(label, isOn: Binding(get: { isOn }, set: { onChange($0) }))
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .disabled(disabled)
      .accessibilityLabel(label)
      .help(hint ?? label)
  }
}

/// A menu picker whose selection is the router's value and whose change is an
/// action rather than a local state write.
struct LocalPicker<Content: View>: View {
  let title: String
  let selection: String
  var disabled = false
  let onSelect: (String) -> Void
  @ViewBuilder let content: () -> Content

  var body: some View {
    Picker(title, selection: Binding(get: { selection }, set: { onSelect($0) })) {
      content()
    }
    .labelsHidden()
    .disabled(disabled)
  }
}
