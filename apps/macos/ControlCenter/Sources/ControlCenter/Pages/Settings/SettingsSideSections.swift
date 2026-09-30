import ControlCenterCore
import SwiftUI

// The right column: vision bridge, desktop tray, appearance, and maintenance.

// MARK: - Vision

struct SettingsVisionEngine: Identifiable, Equatable {
  let slug: String
  let displayName: String
  let efforts: [String]
  var id: String { slug }

  static func list(_ value: JSONValue?) -> [SettingsVisionEngine] {
    (value?.items ?? []).compactMap { item -> SettingsVisionEngine? in
      guard let slug = SettingsValue.nonEmpty(item["slug"]) else { return nil }
      return SettingsVisionEngine(
        slug: slug,
        displayName: SettingsValue.nonEmpty(item["displayName"]) ?? slug,
        efforts: item["efforts"]?.strings ?? []
      )
    }
  }
}

/// The derived engine and effort choices of the vision bridge.
struct SettingsVisionState {
  let paid: [SettingsVisionEngine]
  let native: [SettingsVisionEngine]
  let selectedEngine: String
  /// A pinned engine can leave both lists (a native model that dropped out of
  /// the picker, a provider switched off). Carry it as its own entry so the
  /// menu cannot silently fall back to its first option.
  let unlisted: SettingsVisionEngine?
  let effortOptions: [String]
  let selectedEffort: String
  let resolvedName: String

  init(bridge: JSONValue) {
    let paidEngines = SettingsVisionEngine.list(bridge["paidEngines"])
    let nativeEngines = SettingsVisionEngine.list(bridge["nativeEngines"])
    let engine = SettingsValue.nonEmpty(bridge["engine"]) ?? "auto"
    let meta = (paidEngines + nativeEngines).first { $0.slug == engine }
    let resolved = SettingsValue.nonEmpty(bridge["resolvedEngineName"])
      ?? SettingsValue.nonEmpty(bridge["resolvedEngine"])
      ?? ""
    var unlistedEngine: SettingsVisionEngine?
    if engine != "auto" && engine != "local" && meta == nil {
      unlistedEngine = SettingsVisionEngine(
        slug: engine,
        displayName: resolved.isEmpty ? engine : resolved,
        efforts: []
      )
    }
    var efforts = bridge["availableEfforts"]?.strings ?? []
    if let meta = meta, !meta.efforts.isEmpty { efforts = meta.efforts }
    let effort = SettingsValue.nonEmpty(bridge["effort"]) ?? "default"
    // Same reason as the engine: show the pinned level even when the engine
    // that declared it is no longer listed.
    if effort != "default" && !efforts.contains(effort) { efforts.append(effort) }
    paid = paidEngines
    native = nativeEngines
    selectedEngine = engine
    unlisted = unlistedEngine
    effortOptions = efforts
    selectedEffort = effort
    resolvedName = resolved
  }
}

struct SettingsVisionSection: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var toggles: OptimisticValues<Bool>

  private var t: Translator { model.t }
  private var bridge: JSONValue? { SettingsValue.present(model.target?["modelSettings"]?["visionBridge"]) }

  var body: some View {
    SettingsSection(title: t("settings.vision.title"), description: t("settings.vision.description")) {
      if let bridge = bridge {
        bridgeContent(bridge)
      } else {
        InlineNotice(tone: .neutral, title: t("settings.vision.title"), message: t("settings.vision.unavailable"))
      }
    }
  }

  private func summaryName(_ bridge: JSONValue, _ state: SettingsVisionState) -> String {
    if !state.resolvedName.isEmpty { return state.resolvedName }
    return SettingsValue.nonEmpty(bridge["engine"]) ?? "—"
  }

  @ViewBuilder private func bridgeContent(_ bridge: JSONValue) -> some View {
    let state = SettingsVisionState(bridge: bridge)
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(title: t("settings.vision.enable.title"), detail: t("settings.vision.enable.detail")) {
        SettingsSwitch(
          label: t("settings.vision.enable.title"),
          isOn: toggles.value("vision-bridge", fallback: bridge["enabled"]?.bool == true)
        ) { enabled in
          toggles.mutate(
            "vision-bridge",
            to: enabled,
            label: t("app.action.changeVisionBridge"),
            model: model
          ) { api in
            try await api.setVisionBridgeEnabled(enabled)
          }
        }
      }
      Divider()
      SettingsRow(title: t("settings.vision.engine.title"), detail: t("settings.vision.engine.detail")) {
        engineMenu(bridge, state)
      }
      Divider()
      SettingsRow(
        title: t("settings.vision.effort.title"),
        detail: state.effortOptions.isEmpty ? t("settings.vision.effort.none") : t("settings.vision.effort.detail")
      ) {
        effortMenu(state)
      }
    }
    SettingsSummary(
      systemImage: "eye",
      title: summaryName(bridge, state),
      detail: t("settings.vision.localNote")
    )
  }

  private func engineMenu(_ bridge: JSONValue, _ state: SettingsVisionState) -> some View {
    // No standing "Auto" choice, matching the tray: the ranking behind it
    // scored cost by slug spelling, so it tied across a normal install and
    // resolved alphabetically. It stays visible only while the install is
    // still on it, so the row reports the truth without offering it back.
    let autoName = state.resolvedName.isEmpty ? "—" : state.resolvedName
    let hasLocal = SettingsValue.truthy(bridge["local"])
    let localName = SettingsValue.nonEmpty(bridge["local"]?["model"]) ?? "runtime"
    return SettingsMenuPicker(
      label: t("settings.vision.engine.title"),
      selection: state.selectedEngine,
      onSelect: { engine in
        model.perform(t("app.action.changeVisionEngine")) { api in
          try await api.setVisionBridgeEngine(engine)
        }
      }
    ) {
      if state.selectedEngine == "auto" {
        Text(t("settings.vision.engine.auto", ["name": autoName])).tag("auto")
      }
      if let unlisted = state.unlisted {
        Text(unlisted.displayName).tag(unlisted.slug)
      }
      if !state.paid.isEmpty {
        Section(t("settings.vision.engine.paid")) {
          ForEach(state.paid) { engine in
            Text(engine.displayName).tag(engine.slug)
          }
        }
      }
      if !state.native.isEmpty {
        Section(t("settings.vision.engine.native")) {
          ForEach(state.native) { engine in
            Text(engine.displayName).tag(engine.slug)
          }
        }
      }
      if hasLocal {
        Text(t("settings.vision.engine.local", ["name": localName])).tag("local")
      }
    }
  }

  private func effortMenu(_ state: SettingsVisionState) -> some View {
    SettingsMenuPicker(
      label: t("settings.vision.effort.title"),
      selection: state.selectedEffort,
      disabled: state.effortOptions.isEmpty,
      onSelect: { effort in
        model.perform(t("app.action.changeVisionEffort")) { api in
          try await api.setVisionBridgeEffort(effort)
        }
      }
    ) {
      Text(t("settings.vision.effort.default")).tag("default")
      ForEach(state.effortOptions, id: \.self) { effort in
        Text(Format.effortLabel(effort, t)).tag(effort)
      }
    }
  }
}

// MARK: - Desktop tray

struct SettingsDesktopSection: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: SettingsController
  @Binding var dialog: SettingsDialog?

  private var t: Translator { model.t }
  private var unavailable: Bool { controller.traySupported == false }

  var body: some View {
    SettingsSection(title: t("settings.desktop.title"), description: t("settings.desktop.description")) {
      SettingsSummary(
        systemImage: "macwindow",
        title: t("settings.desktop.tray.title"),
        detail: t("settings.desktop.tray.detail")
      )
      HStack(spacing: 8) {
        SettingsButton(title: t("settings.desktop.enable"), variant: .secondary, disabled: unavailable) {
          model.perform(t("app.action.enableTray")) { api in
            try await api.controlTray("enable")
          }
        }
        SettingsButton(title: t("settings.desktop.restart"), variant: .secondary, disabled: unavailable) {
          model.perform(t("app.action.restartTray")) { api in
            try await api.controlTray("restart")
          }
        }
        SettingsButton(title: t("settings.desktop.disable"), variant: .ghost, disabled: unavailable) {
          dialog = .trayDisable
        }
      }
      if unavailable {
        InlineNotice(
          tone: .neutral,
          title: t("settings.desktop.unavailable.title"),
          message: t("settings.desktop.unavailable.body")
        )
      }
    }
  }
}

// MARK: - Appearance

private struct SettingsThemeButton: View {
  let systemImage: String
  let title: String
  let detail: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: systemImage).font(.system(size: 14))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 12.5, weight: .semibold))
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.selection : Color.clear))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(selected ? Palette.accent : Palette.border)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct SettingsAppearanceSection: View {
  @EnvironmentObject private var model: AppModel
  private var t: Translator { model.t }

  var body: some View {
    SettingsSection(title: t("settings.appearance.title"), description: t("settings.appearance.description")) {
      HStack(alignment: .top, spacing: 8) {
        // The native app follows the macOS appearance by default; the
        // Electron renderer only had light and dark, so there is no message
        // id for this choice.
        SettingsThemeButton(
          systemImage: "circle.lefthalf.filled",
          title: "System",
          detail: "Match macOS",
          selected: model.theme == .system
        ) {
          model.theme = .system
        }
        SettingsThemeButton(
          systemImage: "sun.max",
          title: t("settings.appearance.light"),
          detail: t("settings.appearance.lightDetail"),
          selected: model.theme == .light
        ) {
          model.theme = .light
        }
        SettingsThemeButton(
          systemImage: "moon",
          title: t("settings.appearance.dark"),
          detail: t("settings.appearance.darkDetail"),
          selected: model.theme == .dark
        ) {
          model.theme = .dark
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(t("settings.appearance.aria"))
      SettingsRow(title: t("settings.language.title"), detail: t("settings.language.detail")) {
        Picker(t("settings.language.aria"), selection: languageBinding) {
          ForEach(StringCatalogs.shared.languages) { option in
            Text(option.label).tag(option.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 150, maxWidth: 240)
        .accessibilityLabel(t("settings.language.aria"))
      }
    }
  }

  private var languageBinding: Binding<String> {
    Binding(get: { model.language }, set: { model.language = $0 })
  }
}

// MARK: - Maintenance

struct SettingsMaintenanceSection: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: SettingsController
  @Binding var dialog: SettingsDialog?

  private var t: Translator { model.t }

  /// Repair ran; these checks still fail. Naming them with their own remedy
  /// is the point of showing the report: a bare "it failed" would send the
  /// user back to the terminal the button exists to replace.
  private var failureText: String {
    let checks = controller.repairReport?["checks"]?.items ?? []
    let failures = checks.filter { $0["status"]?.string == "fail" }
    return failures.map { check -> String in
      let name = t.backend(check["name"]?.string)
      let detail = t.backend(check["detail"]?.string)
      let fix = SettingsValue.nonEmpty(check["fix"]).map { " — " + t.backend($0) } ?? ""
      return "\(name): \(detail)\(fix)"
    }.joined(separator: " · ")
  }

  var body: some View {
    let repairPassed = SettingsValue.truthy(controller.repairReport?["ok"])
    let failures = failureText
    SettingsSection(title: t("settings.maintenance.title"), description: t("settings.maintenance.description")) {
      SettingsSummary(
        systemImage: "wrench",
        title: t("settings.maintenance.repairTitle"),
        detail: t("settings.maintenance.footnote")
      )
      HStack(spacing: 8) {
        SettingsButton(
          title: controller.repairing ? t("settings.maintenance.fixRunning") : t("settings.maintenance.fix"),
          variant: .primary,
          disabled: controller.repairing
        ) {
          dialog = .repair
        }
      }
      if repairPassed {
        InlineNotice(
          tone: .success,
          title: t("settings.maintenance.fixDone"),
          message: t("settings.maintenance.fixDoneDetail")
        )
      }
      if !failures.isEmpty {
        InlineNotice(tone: .danger, title: t("settings.maintenance.fixIncomplete"), message: failures)
      }
      InlineNotice(tone: .neutral, title: t("settings.maintenance.update"), message: t("settings.maintenance.updateNote"))
    }
  }
}
