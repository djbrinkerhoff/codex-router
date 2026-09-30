import ControlCenterCore
import SwiftUI

// One place to add a model, searching every connected provider at once. The
// per-provider catalog browsers this replaces made the same list reachable
// only after picking the right provider first. Ports `AddModelsDialog`.

/// Memoizes the flattened catalog list across re-renders; flattening sorts
/// every discovered model, which is too much work to repeat each time the
/// window's health poll redraws the sheet.
final class ModelsCatalogCache {
  private var key: String?
  private var models: [ModelsCatalogModel] = []

  func resolve(_ next: String, build: () -> [ModelsCatalogModel]) -> [ModelsCatalogModel] {
    if key == next { return models }
    let built = build()
    key = next
    models = built
    return built
  }
}

private struct ModelsAddRow: View {
  @EnvironmentObject private var model: AppModel
  let item: ModelsCatalogModel
  let checked: Bool
  let disabled: Bool
  let adding: Bool
  let onToggle: (Bool) -> Void

  private var blocked: Bool { !item.registered && !item.addable }

  var body: some View {
    HStack(spacing: 10) {
      Toggle("", isOn: Binding(get: { checked }, set: { onToggle($0) }))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(disabled)
        .accessibilityLabel(item.displayName)
      ProviderLogo(providerId: item.providerId, displayName: item.providerName, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.displayName)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(item.modelId)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(item.modelId)
        if let reason = item.blockedReason {
          Text(reason)
            .font(.system(size: 11))
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Text(item.providerName)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 110, alignment: .trailing)
      HStack(spacing: 6) {
        if let window = item.contextWindow, window != 0 {
          Text(Format.context(window, model.t))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        if item.isFree { Badge(model.t("models.add.free"), tone: .success) }
      }
      status
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .opacity(blocked ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture {
      if !disabled { onToggle(!checked) }
    }
    .help(item.blockedReason ?? "")
  }

  @ViewBuilder private var status: some View {
    if adding {
      Badge(model.t("models.add.adding"), tone: .neutral)
    } else if item.registered {
      Badge(model.t("models.add.added"), tone: .neutral)
    } else if blocked {
      Badge(model.t("models.add.notSupported"), tone: .neutral)
    }
  }
}

struct ModelsAddSheet: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var store: ModelsStore
  let directory: [ModelsDirectoryEntry]
  let onReload: () -> Void
  let onAdd: ([ModelsCatalogModel]) -> Void
  let onClose: () -> Void
  @State private var query: String
  @State private var selected: [String] = []
  @State private var shownLimit = 120
  @State private var cache = ModelsCatalogCache()

  init(
    store: ModelsStore,
    directory: [ModelsDirectoryEntry],
    initialQuery: String,
    onReload: @escaping () -> Void,
    onAdd: @escaping ([ModelsCatalogModel]) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.store = store
    self.directory = directory
    self.onReload = onReload
    self.onAdd = onAdd
    self.onClose = onClose
    _query = State(initialValue: initialQuery)
  }

  /// What the flattened list depends on: the catalogs loaded so far, and the
  /// directory entries that decide which of them may still be shown.
  private var cacheKey: String {
    let entries = directory.map { entry -> String in
      let sources = (entry.setup?.catalogSources ?? []).map { $0.id }.joined(separator: "+")
      return "\(entry.id):\(entry.displayName):\(entry.setup?.configured ?? false):\(sources)"
    }
    return "\(store.catalogVersion)#" + entries.joined(separator: ",")
  }

  private func catalogModels() -> [ModelsCatalogModel] {
    cache.resolve(cacheKey) {
      ModelsLogic.loadedCatalogModels(directory: directory, catalogStates: store.catalogStates)
    }
  }

  private func matching(_ all: [ModelsCatalogModel]) -> [ModelsCatalogModel] {
    let needle = ModelsLogic.trimmed(query).lowercased()
    if needle.isEmpty { return all }
    return all.filter { item in
      "\(item.displayName) \(item.modelId) \(item.providerName) \(item.sourceName)".lowercased().contains(needle)
    }
  }

  var body: some View {
    let all = catalogModels()
    let found = matching(all)
    let shown = Array(found.prefix(shownLimit))
    let selectedKeys = Set(selected)
    let selectedModels = all.filter { selectedKeys.contains($0.key) }
    let loading = store.loadingConnectedCatalogs
    ModelsDialogFrame(
      title: model.t("models.add.title"),
      description: model.t("models.add.description"),
      width: 700
    ) {
      toolbar(all: all, found: found, loading: loading)
      content(all: all, found: found, shown: shown, selectedKeys: selectedKeys, loading: loading)
      footer(selectedModels)
    }
  }

  // MARK: Toolbar

  private func countText(all: [ModelsCatalogModel], found: [ModelsCatalogModel], loading: Bool) -> String {
    if loading { return model.t("models.add.loadingCatalogs") }
    let count = model.t("models.add.count", ["shown": found.count, "total": all.count])
    // Freshness belongs next to the list it describes: a stored catalog can
    // be up to a day old, and nothing else on this surface would say so.
    let fetched = store.catalogStates.values.compactMap { $0.data?["fetchedAt"]?.text }
    guard let lastRead = fetched.max() else { return count }
    return count + model.t("models.add.read", ["time": Format.dateTime(JSONValue.string(lastRead), model.t)])
  }

  private func toolbar(all: [ModelsCatalogModel], found: [ModelsCatalogModel], loading: Bool) -> some View {
    HStack(spacing: 10) {
      SearchField(text: $query, placeholder: model.t("models.add.search"))
      Text(countText(all: all, found: found, loading: loading))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      Button(loading ? model.t("models.add.asking") : model.t("models.add.reload"), action: onReload)
        .disabled(loading)
    }
  }

  // MARK: Content

  private var failedCatalog: (has: Bool, message: String) {
    let failed = store.catalogStates
      .filter { $0.value.status == .error }
      .sorted { $0.key < $1.key }
    return (!failed.isEmpty, failed.first?.value.error ?? "")
  }

  @ViewBuilder
  private func content(
    all: [ModelsCatalogModel],
    found: [ModelsCatalogModel],
    shown: [ModelsCatalogModel],
    selectedKeys: Set<String>,
    loading: Bool
  ) -> some View {
    if loading && all.isEmpty {
      PanelSkeleton(label: model.t("models.add.loadingProviderCatalogs"), count: 4)
    }
    if !loading && all.isEmpty {
      let failure = failedCatalog
      EmptyStateView(
        systemImage: "magnifyingglass",
        title: failure.has ? model.t("models.add.catalogsFailed") : model.t("models.add.noCatalogs"),
        message: ModelsLogic.nonEmpty(failure.message, or: model.t("models.add.noCatalogsBody"))
      )
    }
    if !shown.isEmpty {
      list(shown, selectedKeys: selectedKeys)
    }
    if found.count > shown.count {
      HStack {
        Text(model.t("models.add.moreModels", ["count": found.count - shown.count]))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer()
        Button(model.t("models.add.showMore")) { shownLimit += 120 }
      }
    }
    if !all.isEmpty && found.isEmpty {
      Text(model.t("models.add.noMatch"))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
  }

  private func list(_ shown: [ModelsCatalogModel], selectedKeys: Set<String>) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(shown) { item in
          let adding = (store.pendingModels[item.providerId]?[item.modelId] ?? 0) > 0
          let blocked = !item.registered && !item.addable
          let atLimit = !selectedKeys.contains(item.key) && selected.count >= ModelsLogic.catalogAddBatchLimit
          ModelsAddRow(
            item: item,
            checked: item.registered || selectedKeys.contains(item.key),
            disabled: item.registered || blocked || adding || atLimit,
            adding: adding,
            onToggle: { toggle(item, $0) }
          )
          Divider()
        }
      }
    }
    .frame(height: 340)
    .panelStyle()
    .accessibilityLabel(model.t("models.add.catalogAria"))
  }

  private func toggle(_ item: ModelsCatalogModel, _ checked: Bool) {
    if !checked {
      selected.removeAll(where: { $0 == item.key })
      return
    }
    if selected.count >= ModelsLogic.catalogAddBatchLimit || selected.contains(item.key) { return }
    selected.append(item.key)
  }

  // MARK: Footer

  private func footer(_ selectedModels: [ModelsCatalogModel]) -> some View {
    let count = selectedModels.count
    let addLabel = count == 0
      ? model.t("models.addModels")
      : model.t("models.add.addCount", [
        "count": count,
        "word": model.t(count == 1 ? "models.add.model" : "models.add.models"),
      ])
    return HStack(spacing: 10) {
      Text(model.t("models.add.hint", ["limit": ModelsLogic.catalogAddBatchLimit]))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button(model.t("models.add.cancel"), action: onClose)
        .keyboardShortcut(.cancelAction)
      Button(addLabel) {
        onAdd(selectedModels)
        selected = []
        onClose()
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .disabled(count == 0)
    }
  }
}
