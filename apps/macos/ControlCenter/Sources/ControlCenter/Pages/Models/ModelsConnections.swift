import ControlCenterCore
import SwiftUI

// The connections strip: one chip per provider, each opening a menu to switch
// the provider on or off, sign in, add a key, or disconnect. Ports
// `ConnectionsBar` and `ProviderMenu`.

/// Which chips the strip shows, and which of them are connected or busy.
private struct ModelsChipPlan {
  /// Every operator-added endpoint lives under the Custom container: one chip
  /// for the lot, with the endpoints listed inside it, instead of a chip each.
  let container: ModelsDirectoryEntry?
  let endpoints: [ModelsDirectoryEntry]
  let chips: [ModelsDirectoryEntry]
  let enabledProviders: Set<String>
  let pending: [String: ModelsProviderMutation]

  init(directory: [ModelsDirectoryEntry], enabledProviders: Set<String>, pending: [String: ModelsProviderMutation]) {
    let container = directory.first(where: { $0.setup?.kind == "per-model" })
    let endpoints: [ModelsDirectoryEntry] = container == nil
      ? []
      : directory.filter { $0.setup?.generic == true }
    let endpointIds = Set(endpoints.map { $0.id })
    self.container = container
    self.endpoints = endpoints
    self.chips = directory.filter { !endpointIds.contains($0.id) }
    self.enabledProviders = enabledProviders
    self.pending = pending
  }

  func isContainer(_ entry: ModelsDirectoryEntry) -> Bool {
    entry.id == container?.id
  }

  func isConnected(_ entry: ModelsDirectoryEntry) -> Bool {
    ModelsLogic.providerConnected(entry, enabledProviders) || (isContainer(entry) && !endpoints.isEmpty)
  }

  /// A custom endpoint is managed from inside the Custom chip, so a mutation
  /// on one of them has to surface on the container that stands for it.
  func pendingOf(_ entry: ModelsDirectoryEntry) -> ModelsProviderMutation? {
    if let own = pending[entry.id] { return own }
    if isContainer(entry) {
      for endpoint in endpoints {
        if let inner = pending[endpoint.id] { return inner }
      }
    }
    return nil
  }

  /// Placement is optimistic, the count is not: a provider whose key is still
  /// being published belongs where the operator will look for it, but it has
  /// not been proven connected yet.
  func onStrip(_ entry: ModelsDirectoryEntry) -> Bool {
    isConnected(entry) || pendingOf(entry) != nil
  }

  var connected: [ModelsDirectoryEntry] { chips.filter { onStrip($0) } }
  var available: [ModelsDirectoryEntry] { chips.filter { !onStrip($0) } }
  var connectedCount: Int { chips.filter { isConnected($0) }.count }

  func dotEnabled(_ entry: ModelsDirectoryEntry, _ isEnabled: (ModelsDirectoryEntry) -> Bool) -> Bool {
    if isContainer(entry) && !endpoints.isEmpty {
      return endpoints.contains(where: { isEnabled($0) }) || (!entry.models.isEmpty && isEnabled(entry))
    }
    return isEnabled(entry)
  }
}

struct ModelsConnectionsBar: View {
  @EnvironmentObject private var model: AppModel
  let directory: [ModelsDirectoryEntry]
  let enabledProviders: Set<String>
  let pendingMutations: [String: ModelsProviderMutation]
  let usageById: [String: JSONValue]
  let openProviderId: String?
  @Binding var connectMenuOpen: Bool
  let isEnabled: (ModelsDirectoryEntry) -> Bool
  let onOpenProvider: (String) -> Void
  let onCloseProvider: () -> Void
  let onEnabledChange: (ModelsDirectoryEntry, Bool) -> Void
  let onSignIn: (ModelsDirectoryEntry) -> Void
  let onConfigure: (ModelsDirectoryEntry) -> Void
  let onKey: (ModelsDirectoryEntry) -> Void
  let onRemove: (ModelsDirectoryEntry) -> Void
  let onAddEndpoint: () -> Void
  let onEditEndpoint: (ModelsDirectoryEntry) -> Void
  let onAddEndpointModels: (ModelsDirectoryEntry) -> Void
  let onAddNamedModel: (ModelsDirectoryEntry) -> Void
  let onRemoveEndpointModel: (ModelsDirectoryEntry, ModelsRoute) -> Void

  var body: some View {
    let plan = ModelsChipPlan(directory: directory, enabledProviders: enabledProviders, pending: pendingMutations)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(model.t("models.connections"))
          .font(.system(size: 13.5, weight: .semibold))
        Text(model.t("models.connectionsCount", ["connected": plan.connectedCount, "total": plan.chips.count]))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)],
        alignment: .leading,
        spacing: 8
      ) {
        ForEach(plan.connected) { entry in
          chip(entry, plan)
        }
        if !plan.available.isEmpty {
          connectChip(plan)
        }
      }
    }
    .panelStyle(padding: 12)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.t("models.providerConnectionsAria"))
  }

  // MARK: Chips

  private func chip(_ entry: ModelsDirectoryEntry, _ plan: ModelsChipPlan) -> some View {
    let pending = plan.pendingOf(entry)
    let openEndpoint = plan.endpoints.first(where: { $0.id == openProviderId })
    let shown: ModelsDirectoryEntry? = openProviderId == entry.id
      ? entry
      : (plan.isContainer(entry) ? openEndpoint : nil)
    let dot = plan.dotEnabled(entry, isEnabled)
    let presented = Binding<Bool>(
      get: { shown != nil },
      set: { isOpen in if !isOpen { onCloseProvider() } }
    )
    return Button {
      connectMenuOpen = false
      onOpenProvider(entry.id)
    } label: {
      chipLabel(entry, pending: pending, dotEnabled: dot)
    }
    .buttonStyle(.plain)
    .disabled(pending != nil)
    .popover(isPresented: presented, arrowEdge: .bottom) {
      if let shown {
        providerMenu(shown, chipEntry: entry, plan: plan, openEndpoint: openEndpoint)
          .environmentObject(model)
      }
    }
  }

  private func chipLabel(_ entry: ModelsDirectoryEntry, pending: ModelsProviderMutation?, dotEnabled: Bool) -> some View {
    HStack(spacing: 6) {
      ProviderLogo(providerId: entry.id, displayName: entry.displayName, size: 18)
      Text(entry.displayName)
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
      Spacer(minLength: 4)
      // The dot reports an account state this chip has not reached yet, so
      // while the transaction runs its slot says what is running instead.
      if let pending {
        HStack(spacing: 4) {
          ProgressView().controlSize(.mini)
          Text(pending == .disconnecting
            ? model.t("models.connection.disconnecting")
            : model.t("models.connection.connecting"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } else {
        let stalled = dotEnabled && runtimeStopped(entry)
        Circle()
          .fill(stalled ? Palette.warning : (dotEnabled ? Palette.success : Color.secondary.opacity(0.4)))
          .frame(width: 7, height: 7)
          .help(stalled ? model.t("local.ollama.notRunning") : "")
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border))
    .contentShape(Rectangle())
  }

  /// The Ollama provider is switched on but its runtime is not answering, so
  /// its models cannot be served however the switch is set. A green dot would
  /// contradict the Local page.
  private func runtimeStopped(_ entry: ModelsDirectoryEntry) -> Bool {
    guard entry.id == "local",
          let runtime = model.target?["modelSettings"]?["localModels"]?["runtime"] else { return false }
    return runtime["running"]?.bool != true
  }

  private func providerMenu(
    _ shown: ModelsDirectoryEntry,
    chipEntry: ModelsDirectoryEntry,
    plan: ModelsChipPlan,
    openEndpoint: ModelsDirectoryEntry?
  ) -> some View {
    var back: (() -> Void)?
    if shown.id == openEndpoint?.id {
      back = { onOpenProvider(chipEntry.id) }
    }
    return ModelsProviderMenu(
      entry: shown,
      usage: usageById[shown.id],
      enabled: isEnabled(shown),
      endpoints: shown.id == plan.container?.id ? plan.endpoints : nil,
      isEndpointEnabled: isEnabled,
      onOpenEndpoint: onOpenProvider,
      onBack: back,
      backLabel: chipEntry.displayName,
      onEnabledChange: { onEnabledChange(shown, $0) },
      onSignIn: { onSignIn(shown) },
      onKey: { onKey(shown) },
      onRemove: { onRemove(shown) },
      onAddEndpoint: onAddEndpoint,
      onEditEndpoint: { onEditEndpoint(shown) },
      onAddModels: { onAddEndpointModels(shown) },
      onAddNamedModel: { onAddNamedModel(shown) },
      onRemoveModel: { onRemoveEndpointModel(shown, $0) }
    )
  }

  // MARK: Connect menu

  private func connectChip(_ plan: ModelsChipPlan) -> some View {
    let available = plan.available
    return Button {
      onCloseProvider()
      connectMenuOpen.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
        Text(model.t("models.connectProvider"))
          .font(.system(size: 12.5, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $connectMenuOpen, arrowEdge: .bottom) {
      connectMenu(available)
        .environmentObject(model)
    }
  }

  private func connectMenu(_ available: [ModelsDirectoryEntry]) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(available) { entry in
          Button {
            connectMenuOpen = false
            choose(entry)
          } label: {
            HStack(spacing: 8) {
              ProviderLogo(providerId: entry.id, displayName: entry.displayName, size: 18)
              Text(entry.displayName).font(.system(size: 12.5))
              Spacer(minLength: 8)
              Text(ModelsLogic.connectionMethod(entry, model.t))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(entry.setup == nil)
        }
      }
      .padding(4)
    }
    .frame(width: 330, height: min(360, CGFloat(available.count) * 34 + 12))
    .accessibilityLabel(model.t("models.providersYouCanConnect"))
  }

  private func choose(_ entry: ModelsDirectoryEntry) {
    guard let setup = entry.setup else { return }
    if setup.kind == "oauth" || setup.signIn {
      onSignIn(entry)
    } else if setup.kind == "configuration" {
      onConfigure(entry)
    } else if setup.kind == "anonymous" {
      onEnabledChange(entry, true)
    } else if setup.kind == "per-model" {
      onAddEndpoint()
    } else {
      onKey(entry)
    }
  }
}

// MARK: - Provider menu

struct ModelsProviderMenu: View {
  @EnvironmentObject private var model: AppModel
  let entry: ModelsDirectoryEntry
  let usage: JSONValue?
  let enabled: Bool
  let endpoints: [ModelsDirectoryEntry]?
  let isEndpointEnabled: (ModelsDirectoryEntry) -> Bool
  let onOpenEndpoint: (String) -> Void
  let onBack: (() -> Void)?
  let backLabel: String
  let onEnabledChange: (Bool) -> Void
  let onSignIn: () -> Void
  let onKey: () -> Void
  let onRemove: () -> Void
  let onAddEndpoint: () -> Void
  let onEditEndpoint: () -> Void
  let onAddModels: () -> Void
  let onAddNamedModel: () -> Void
  let onRemoveModel: (ModelsRoute) -> Void

  var body: some View {
    let setup = entry.setup
    // The Custom container is a launcher, not an account: until it holds
    // models of its own there is nothing to switch off and no traffic to
    // report.
    let launcher = setup?.kind == "per-model"
    let emptyLauncher = launcher && entry.models.isEmpty
    VStack(alignment: .leading, spacing: 10) {
      if let onBack {
        Button(action: onBack) {
          Label(backLabel, systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11.5))
      }
      header(launcher: launcher)
      Text(copyText(setup))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      usageLine(emptyLauncher: emptyLauncher)
      if let setup {
        controls(setup, launcher: launcher, emptyLauncher: emptyLauncher)
      }
    }
    .padding(14)
    .frame(width: 340)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.t("models.connection.dialog", ["name": entry.displayName]))
  }

  private func header(launcher: Bool) -> some View {
    HStack(spacing: 10) {
      ProviderLogo(providerId: entry.id, displayName: entry.displayName, size: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.displayName).font(.system(size: 14, weight: .semibold))
        Text(
          launcher
            ? ModelsLogic.launcherSummary(entry, endpointCount: endpoints?.count ?? 0, model.t)
            : ModelsLogic.connectionMethod(entry, model.t)
        )
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  private func copyText(_ setup: ModelsSetup?) -> String {
    let t = model.t
    if let setup, setup.generic {
      let format = setup.adapter == "openai-responses" ? "Responses API" : "Chat Completions"
      let noKey = setup.hasKey ? "" : t("customEndpoint.noKeySuffix")
      return "\(setup.baseUrl) · \(format)\(noKey)"
    }
    if setup?.kind == "per-model" { return t("customEndpoint.introduction") }
    let note = t.backend(setup?.planNote)
    if !note.isEmpty { return note }
    return ModelsLogic.connectionDetail(
      entry,
      t,
      accountStatus: usage?["account"]?["status"]?.string,
      accountMessage: usage?["account"]?["message"]?.string,
      canOpenTerminal: ModelsLogic.platform == "darwin"
    )
  }

  @ViewBuilder private func usageLine(emptyLauncher: Bool) -> some View {
    if let requests = usage?["requests"]?.int, requests != 0, !emptyLauncher {
      Text(model.t(
        requests == 1 ? "models.connection.oneRequestSoFar" : "models.connection.requestsSoFar",
        ["count": requests]
      ))
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
  }

  // MARK: Controls

  @ViewBuilder private func controls(_ setup: ModelsSetup, launcher: Bool, emptyLauncher: Bool) -> some View {
    if !emptyLauncher {
      HStack {
        Text(model.t("models.connection.available")).font(.system(size: 12.5))
        Spacer(minLength: 8)
        ModelsSwitch(
          checked: enabled,
          disabled: !setup.configured,
          label: model.t("models.connection.makeAvailable", ["name": entry.displayName]),
          onChange: onEnabledChange
        )
      }
    }
    if setup.generic {
      endpointModels(setup)
    }
    if launcher, let endpoints, !endpoints.isEmpty {
      endpointList(endpoints)
    }
    actions(setup, launcher: launcher)
  }

  private func endpointModels(_ setup: ModelsSetup) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(model.t("nav.models")).font(.system(size: 12.5, weight: .semibold))
        Spacer(minLength: 8)
        Button(action: onAddModels) {
          Label(model.t("models.addModels"), systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(!setup.configured || setup.enabled == false)
        Button(action: onAddNamedModel) {
          Label(model.t("customEndpoint.byName"), systemImage: "pencil")
        }
        .buttonStyle(.borderless)
        .disabled(setup.enabled == false)
      }
      if entry.models.isEmpty {
        Text(model.t("customEndpoint.noModels"))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(entry.models.enumerated()), id: \.offset) { item in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(item.element.displayName).font(.system(size: 12.5))
              Text(item.element.slug)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
              onRemoveModel(item.element)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(model.t("customEndpoint.removeModel"))
            .accessibilityLabel(model.t("customEndpoint.action.removeModel", ["name": item.element.displayName]))
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.t("customEndpoint.modelsAria", ["name": entry.displayName]))
  }

  private func endpointList(_ endpoints: [ModelsDirectoryEntry]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.t("customEndpoint.listTitle")).font(.system(size: 12.5, weight: .semibold))
      ForEach(endpoints) { endpoint in
        Button {
          onOpenEndpoint(endpoint.id)
        } label: {
          HStack(spacing: 8) {
            Circle()
              .fill(isEndpointEnabled(endpoint) ? Palette.success : Color.secondary.opacity(0.4))
              .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
              Text(endpoint.displayName).font(.system(size: 12.5))
              Text(endpointSummary(endpoint))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 3)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.t("customEndpoint.listAria"))
  }

  private func endpointSummary(_ endpoint: ModelsDirectoryEntry) -> String {
    let count = endpoint.models.count
    let models = model.t(count == 1 ? "customEndpoint.modelCountOne" : "customEndpoint.modelCount", ["count": count])
    return "\(endpoint.setup?.baseUrl ?? "") · \(models)"
  }

  private func signInLabel(_ setup: ModelsSetup) -> String {
    if setup.action == "probe" { return model.t("models.connection.runLiveTest") }
    return setup.configured ? model.t("models.connection.signInAgain") : model.t("models.connection.openSignIn")
  }

  @ViewBuilder private func actions(_ setup: ModelsSetup, launcher: Bool) -> some View {
    let terminalCapable = entry.id == "antigravity-oauth" || ModelsLogic.platform == "darwin"
    VStack(alignment: .leading, spacing: 6) {
      if setup.generic {
        Button(action: onEditEndpoint) {
          Label(model.t("customEndpoint.edit"), systemImage: "pencil")
        }
      }
      if setup.kind == "oauth" || setup.signIn {
        Button(action: onSignIn) {
          Label(signInLabel(setup), systemImage: "arrow.right.circle")
        }
        .disabled(setup.action == "blocked" || !terminalCapable)
        .help(terminalCapable ? "" : model.t("models.connection.terminalOnly"))
      }
      if setup.kind == "per-model" {
        Button(action: onAddEndpoint) {
          Label(model.t("customEndpoint.add"), systemImage: "plus")
        }
      }
      if setup.kind == "api" && entry.id != "local" {
        Button(action: onKey) {
          Label(
            setup.configured ? model.t("models.connection.replaceKey") : model.t("models.connection.addKey"),
            systemImage: "key"
          )
        }
      }
      if ((setup.kind == "api" && setup.configured) || setup.disconnectable) && entry.id != "local" {
        Button(action: onRemove) {
          Label(
            setup.generic ? model.t("customEndpoint.remove") : model.t("models.disconnect.confirm"),
            systemImage: "trash"
          )
        }
      }
    }
  }
}
