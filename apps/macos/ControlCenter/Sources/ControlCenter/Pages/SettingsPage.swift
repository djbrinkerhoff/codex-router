import ControlCenterCore
import SwiftUI

/// Routing, the ChatGPT subscription-account pool, the background service,
/// Token maxxing, the vision bridge, the desktop tray, appearance and
/// maintenance. Ported from `SettingsPage.tsx`; the sections live under
/// `Pages/Settings/`.
struct SettingsPage: View {
  @EnvironmentObject private var model: AppModel
  /// Login polling, the optimistic account list, the tray probe, and the
  /// repair run. Its tasks are cancelled when the page disappears.
  @StateObject private var controller = SettingsController()
  @StateObject private var toggles = OptimisticValues<Bool>()
  @State private var dialog: SettingsDialog?

  private var t: Translator { model.t }

  /// The router's authoritative switch positions, which settle the
  /// optimistic ones.
  private var toggleStates: [String: Bool] {
    let modelSettings = model.target?["modelSettings"]
    let aging = modelSettings?["toolResultAging"]
    let bridge = modelSettings?["visionBridge"]
    return [
      "signed-routing": model.target?["signedRouting"]?.bool == true,
      "tool-result-aging": aging?["enabled"]?.bool == true,
      "native-tool-result-aging": aging?["nativeEnabled"]?.bool == true,
      "vision-bridge": bridge?["enabled"]?.bool == true,
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: t("settings.eyebrow"),
        title: t("settings.title"),
        description: t("settings.description"),
        onRefresh: { Task { await model.refreshAll() } }
      )
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 16) {
          SettingsRoutingSection(toggles: toggles, dialog: $dialog)
          SettingsAccountsSection(controller: controller, dialog: $dialog)
          SettingsServiceSection()
          SettingsContextSection(toggles: toggles)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        VStack(alignment: .leading, spacing: 16) {
          SettingsVisionSection(toggles: toggles)
          SettingsDesktopSection(controller: controller, dialog: $dialog)
          SettingsAppearanceSection()
          SettingsMaintenanceSection(controller: controller, dialog: $dialog)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .onAppear {
      controller.probeTray(model: model)
      controller.reconcileOverlays(pool: model.accountPool, error: model.readErrors[.accountPool])
      controller.evaluateLogin(model: model)
    }
    .onDisappear { controller.stop() }
    .onChange(of: model.refreshing) { _ in
      controller.probeTray(model: model)
    }
    .onChange(of: model.accountPool) { _ in
      controller.reconcileOverlays(pool: model.accountPool, error: model.readErrors[.accountPool])
      controller.evaluateLogin(model: model)
    }
    .onChange(of: model.readErrors[.accountPool]) { _ in
      controller.reconcileOverlays(pool: model.accountPool, error: model.readErrors[.accountPool])
    }
    .onChange(of: toggleStates) { states in
      toggles.reconcile(with: states)
    }
    .sheet(item: $dialog) { item in
      dialogView(item)
    }
  }

  // MARK: Dialogs

  @ViewBuilder private func dialogView(_ item: SettingsDialog) -> some View {
    switch item {
    case .sessionSharing:
      SettingsConfirmDialog(
        title: t("settings.chatgptSession.confirm.title"),
        description: t("settings.chatgptSession.confirm.description"),
        message: t("settings.chatgptSession.confirm.body"),
        cancelLabel: t("settings.desktop.confirm.cancel"),
        confirmLabel: t("settings.chatgptSession.confirm.enable"),
        onCancel: { dialog = nil },
        onConfirm: {
          dialog = nil
          model.perform(t("settings.chatgptSession.action.enable")) { api in
            try await api.setChatGptSessionSharing(true)
          }
        }
      )
    case .repair:
      SettingsConfirmDialog(
        title: t("settings.maintenance.confirm.title"),
        description: t("settings.maintenance.confirm.description"),
        message: t("settings.maintenance.confirm.body"),
        cancelLabel: t("settings.desktop.confirm.cancel"),
        confirmLabel: t("settings.maintenance.fix"),
        onCancel: { dialog = nil },
        onConfirm: {
          dialog = nil
          controller.runRepair(model: model)
        }
      )
    case .trayDisable:
      SettingsConfirmDialog(
        title: t("settings.desktop.confirm.title"),
        description: t("settings.desktop.confirm.description"),
        message: t("settings.desktop.confirm.body"),
        cancelLabel: t("settings.desktop.confirm.cancel"),
        confirmLabel: t("settings.desktop.disable"),
        confirmVariant: .danger,
        confirmDisabled: controller.traySupported == false,
        onCancel: { dialog = nil },
        onConfirm: {
          dialog = nil
          model.perform(t("app.action.disableTray")) { api in
            try await api.controlTray("disable")
          }
        }
      )
    case .removeAccount(let accountId):
      SettingsConfirmDialog(
        title: t("settings.accounts.removeTitle"),
        description: t("settings.accounts.removeDescription"),
        message: t("settings.accounts.removeBody"),
        cancelLabel: t("settings.accounts.removeCancel"),
        confirmLabel: t("settings.accounts.removeConfirm"),
        confirmVariant: .danger,
        confirmDisabled: accountId.isEmpty || controller.loginPendingId == accountId,
        onCancel: { dialog = nil },
        onConfirm: {
          if controller.removeAccount(accountId, model: model) { dialog = nil }
        }
      )
    }
  }
}
