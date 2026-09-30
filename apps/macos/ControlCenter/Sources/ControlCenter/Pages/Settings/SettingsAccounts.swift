import ControlCenterCore
import SwiftUI

/// An optimistic change to the account list that paints before the router
/// confirms it. `runAction`'s later refresh replaces it with the
/// authoritative pool and the matching overlay is dropped.
enum SettingsAccountOverlay: Equatable {
  case add(clientId: String, account: JSONValue)
  case remove(accountId: String)
}

struct SettingsAccountRow: Identifiable, Equatable {
  let id: String
  let account: JSONValue
}

/// The Settings page's asynchronous state: the ChatGPT subscription-account
/// flow (optimistic add/remove, the login poll), the tray capability probe,
/// and the repair run. The page owns it as a `@StateObject`, so every task it
/// starts is cancelled when the page goes away.
@MainActor
final class SettingsController: ObservableObject {
  static let pollIntervalNanoseconds: UInt64 = 1_500_000_000

  @Published var newAccountLabel = ""
  @Published private(set) var loginPendingId: String?
  @Published private(set) var loginRetryingId: String?
  @Published private(set) var loginError: String?
  @Published private(set) var overlays: [SettingsAccountOverlay] = []
  @Published private(set) var traySupported: Bool?
  @Published private(set) var repairing = false
  @Published private(set) var repairReport: JSONValue?

  private var pollTask: Task<Void, Never>?
  private var trayTask: Task<Void, Never>?

  /// Cancels every task this controller owns. Called when the page disappears.
  func stop() {
    stopPolling()
    trayTask?.cancel()
    trayTask = nil
  }

  // MARK: Tray capability

  /// `api.controlTray("status")`, re-read whenever a refresh starts or ends.
  /// A stale answer is ignored once a newer probe has begun.
  func probeTray(model: AppModel) {
    trayTask?.cancel()
    let api = model.api
    trayTask = Task { [weak self] in
      do {
        let result = try await api.controlTray("status")
        if Task.isCancelled { return }
        self?.traySupported = result["status"]?["supported"]?.bool
      } catch {
        if Task.isCancelled { return }
        self?.traySupported = nil
      }
    }
  }

  // MARK: Account list

  static func placeholder(label: String, clientId: String) -> JSONValue {
    let subscription: JSONValue = [
      "status": "pending",
      "authenticated": false,
      "usable": false,
      "expired": false,
    ]
    // An empty label renders as the localized default title.
    return [
      "id": .string(clientId),
      "state": "active",
      "paused": false,
      "priority": 50,
      "label": .string(label),
      "subscription": subscription,
      "turns": 0,
      "requests": 0,
    ]
  }

  /// Revoked records are cleanup tombstones from older router versions. They
  /// are not usable accounts and must never reappear as "Account 1/2" rows.
  /// Paused records stay visible. Add/remove overlays paint immediately.
  static func visibleAccounts(
    pool: JSONValue?,
    poolError: String?,
    overlays: [SettingsAccountOverlay]
  ) -> [SettingsAccountRow] {
    var base: [SettingsAccountRow] = []
    if poolError == nil, let accounts = pool?["accounts"]?.object {
      for (key, value) in accounts where value["state"]?.string != "revoked" {
        base.append(SettingsAccountRow(id: value["id"]?.string ?? key, account: value))
      }
    }
    // The pool is a JSON object, so its insertion order is not preserved;
    // creation time (then id) restores the order the accounts were added in.
    base.sort { left, right in
      let leftCreated = left.account["createdAt"]?.string ?? ""
      let rightCreated = right.account["createdAt"]?.string ?? ""
      if leftCreated == rightCreated { return left.id < right.id }
      return leftCreated < rightCreated
    }
    var removedIds = Set<String>()
    var addedAccounts: [JSONValue] = []
    for entry in overlays {
      switch entry {
      case .remove(let accountId): removedIds.insert(accountId)
      case .add(_, let account): addedAccounts.append(account)
      }
    }
    let visible = base.filter { !removedIds.contains($0.id) }
    let visibleIds = Set(visible.map { $0.id })
    var pendingAdds: [SettingsAccountRow] = []
    for account in addedAccounts {
      guard let id = account["id"]?.string, !visibleIds.contains(id) else { continue }
      pendingAdds.append(SettingsAccountRow(id: id, account: account))
    }
    return visible + pendingAdds
  }

  static func isUsable(_ row: SettingsAccountRow) -> Bool {
    row.account["state"]?.string == "active" && row.account["subscription"]?["usable"]?.bool == true
  }

  /// `profile.desired || profile.active || first usable account || ""`.
  static func selection(pool: JSONValue?, accounts: [SettingsAccountRow]) -> String {
    if let desired = SettingsValue.nonEmpty(pool?["profile"]?["desired"]) { return desired }
    if let active = SettingsValue.nonEmpty(pool?["profile"]?["active"]) { return active }
    for row in accounts where isUsable(row) { return row.id }
    return ""
  }

  /// Drops every overlay the authoritative pool now agrees with.
  func reconcileOverlays(pool: JSONValue?, error: String?) {
    guard error == nil, let pool = pool, !overlays.isEmpty else { return }
    let accounts = pool["accounts"]
    let next = overlays.filter { entry -> Bool in
      switch entry {
      case .add(_, let account):
        return !SettingsValue.exists(accounts?[account["id"]?.string ?? ""])
      case .remove(let accountId):
        guard let remaining = SettingsValue.present(accounts?[accountId]) else { return false }
        return remaining["state"]?.string != "revoked"
      }
    }
    if next.count != overlays.count { overlays = next }
  }

  private func replaceAddOverlay(_ clientId: String, with created: JSONValue) {
    overlays = overlays.map { entry -> SettingsAccountOverlay in
      if case .add(let id, _) = entry, id == clientId {
        return .add(clientId: clientId, account: created)
      }
      return entry
    }
  }

  private func dropAddOverlay(_ clientId: String) {
    overlays.removeAll { entry in
      if case .add(let id, _) = entry { return id == clientId }
      return false
    }
  }

  private func dropRemoveOverlay(_ accountId: String) {
    overlays.removeAll { entry in
      if case .remove(let id) = entry { return id == accountId }
      return false
    }
  }

  // MARK: Add, select, remove

  func addAccount(model: AppModel) {
    guard model.readErrors[.accountPool] == nil else { return }
    let label = newAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let clientId = "pending:" + UUID().uuidString.lowercased()
    overlays.append(.add(clientId: clientId, account: Self.placeholder(label: label, clientId: clientId)))
    newAccountLabel = ""
    let api = model.api
    let actionLabel = model.t("app.action.addChatgptAccount")
    Task {
      var saved = false
      await model.runAction(actionLabel) {
        let result = try await api.addChatGptSubscriptionAccount(label: label)
        if let created = result["account"], SettingsValue.nonEmpty(created["id"]) != nil {
          self.replaceAddOverlay(clientId, with: created)
        } else {
          // The durable write succeeded but returned no row. Drop the
          // placeholder so the refreshed pool is the only source.
          self.dropAddOverlay(clientId)
        }
        saved = true
        return result
      }
      if !saved { self.dropAddOverlay(clientId) }
    }
  }

  /// Returns whether the removal started, so the page can close its dialog.
  @discardableResult
  func removeAccount(_ accountId: String, model: AppModel) -> Bool {
    guard !accountId.isEmpty, loginPendingId != accountId else { return false }
    overlays.append(.remove(accountId: accountId))
    let api = model.api
    let actionLabel = model.t("app.action.removeChatgptAccount")
    Task {
      var saved = false
      await model.runAction(actionLabel) {
        _ = try await api.removeChatGptSubscriptionAccount(accountId)
        saved = true
        return .null
      }
      if !saved { self.dropRemoveOverlay(accountId) }
    }
    return true
  }

  // MARK: Login

  /// Starts a login for one account and begins observing the router's
  /// projection of it. `hadFailedAttempt` marks a retry, whose stale failed
  /// projection is ignored until the router reports the new attempt.
  func startLogin(accountId: String, name: String, hadFailedAttempt: Bool, model: AppModel) {
    loginError = nil
    loginRetryingId = hadFailedAttempt ? accountId : nil
    loginPendingId = accountId
    let api = model.api
    let actionLabel = model.t("app.action.loginChatgptAccount", ["name": name])
    evaluateLogin(model: model)
    Task {
      await model.runAction(actionLabel) {
        do {
          return try await api.loginChatGptSubscriptionAccount(accountId)
        } catch {
          // runAction owns and swallows action failures after showing the
          // toast. Clear the pending owner before rethrowing so a launch or
          // pre-handoff failure cannot leave the completion poll running.
          self.loginPendingId = nil
          self.loginRetryingId = nil
          self.stopPolling()
          throw error
        }
      }
      self.evaluateLogin(model: model)
    }
  }

  /// The login effect of `SettingsPage.tsx`: stop when the account became
  /// usable or the attempt failed, otherwise keep polling. Called whenever the
  /// pool or the pending login changes.
  func evaluateLogin(model: AppModel) {
    guard let pendingId = loginPendingId else {
      stopPolling()
      return
    }
    let pool = model.accountPool
    let observed = pool?["loginAttempts"]?[pendingId]
    let observedStatus = observed?["status"]?.string
    if pendingId == loginRetryingId && observedStatus == "pending" {
      loginRetryingId = nil
    }
    var attempt = observed
    if pendingId == loginRetryingId && observedStatus == "failed" {
      attempt = nil
    }
    let attemptExists = SettingsValue.exists(attempt)
    let accountUsable = pool?["accounts"]?[pendingId]?["subscription"]?["usable"]?.bool == true
    if accountUsable && !attemptExists {
      loginPendingId = nil
      loginRetryingId = nil
      loginError = nil
      stopPolling()
      return
    }
    if attempt?["status"]?.string == "failed" {
      loginPendingId = nil
      loginRetryingId = nil
      loginError = SettingsValue.nonEmpty(attempt?["error"]) ?? (model.t("settings.accounts.loginFailed") + ".")
      stopPolling()
      return
    }
    startPolling(model: model)
  }

  /// A refresh every 1.5 seconds while a login is pending. One task at most;
  /// it ends on the first cancellation.
  private func startPolling(model: AppModel) {
    guard pollTask == nil else { return }
    pollTask = Task { [weak model] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: SettingsController.pollIntervalNanoseconds)
        if Task.isCancelled { return }
        guard let model = model else { return }
        await model.refreshAll()
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  // MARK: Repair

  /// Repair reinstalls and restarts the service, so it can outlast several
  /// ordinary actions. `runAction` owns the toast and the refresh; the report
  /// is kept here as well because a repair that finishes with checks still
  /// failing needs to say which ones.
  func runRepair(model: AppModel) {
    guard !repairing else { return }
    repairing = true
    repairReport = nil
    let api = model.api
    let actionLabel = model.t("settings.maintenance.fix")
    Task {
      await model.runAction(actionLabel) {
        let report = try await api.repairInstall()
        self.repairReport = report
        if !SettingsValue.truthy(report["ok"]) {
          let checks = report["checks"]?.items ?? []
          let failed = checks.first { $0["status"]?.string == "fail" }
          if let failed = failed {
            let name = failed["name"]?.string ?? ""
            let detail = SettingsValue.nonEmpty(failed["detail"]) ?? "check failed"
            throw ControlCenterError("\(name): \(detail)")
          }
          throw ControlCenterError("Repair finished with failing checks.")
        }
        return report
      }
      self.repairing = false
    }
  }
}

// MARK: - Section

struct SettingsAccountsSection: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: SettingsController
  @Binding var dialog: SettingsDialog?

  private var t: Translator { model.t }
  private var pool: JSONValue? { model.accountPool }
  private var poolError: String? { model.readErrors[.accountPool] }

  var body: some View {
    let accounts = SettingsController.visibleAccounts(pool: pool, poolError: poolError, overlays: controller.overlays)
    let selection = SettingsController.selection(pool: pool, accounts: accounts)
    SettingsSection(title: t("settings.accounts.title"), description: t("settings.accounts.description")) {
      notice
      createRow
      accountList(accounts, selection: selection)
      if poolError == nil && accounts.isEmpty {
        SettingsSummary(
          systemImage: "checkmark.shield",
          title: t("settings.accounts.emptyTitle"),
          detail: t("settings.accounts.emptyBody")
        )
      }
    }
  }

  @ViewBuilder private var notice: some View {
    if let error = poolError {
      InlineNotice(
        tone: .danger,
        title: t("settings.accounts.stateUnavailable"),
        message: t("settings.accounts.stateUnavailableBody", ["error": error])
      )
    } else if let loginError = controller.loginError {
      InlineNotice(
        tone: .danger,
        title: t("settings.accounts.loginFailed"),
        message: t("settings.accounts.loginFailedBody", ["error": loginError])
      )
    } else if SettingsValue.truthy(pool?["profile"]?["pending"]) {
      InlineNotice(
        tone: .neutral,
        title: t("settings.accounts.switchPending"),
        message: t("settings.accounts.switchPendingBody")
      )
    }
  }

  private var createRow: some View {
    HStack(spacing: 8) {
      TextField(t("settings.accounts.labelPlaceholder"), text: $controller.newAccountLabel)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(t("settings.accounts.newLabelAria"))
        .onChange(of: controller.newAccountLabel) { value in
          if value.count > 120 { controller.newAccountLabel = String(value.prefix(120)) }
        }
      SettingsButton(
        title: t("settings.accounts.add"),
        systemImage: "plus",
        variant: .secondary,
        disabled: poolError != nil
      ) {
        controller.addAccount(model: model)
      }
    }
  }

  @ViewBuilder private func accountList(_ accounts: [SettingsAccountRow], selection: String) -> some View {
    if !accounts.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, row in
          if index > 0 { Divider() }
          SettingsAccountRowView(
            controller: controller,
            dialog: $dialog,
            row: row,
            selected: selection == row.id
          )
        }
      }
    }
  }
}

private struct SettingsAccountRowView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var controller: SettingsController
  @Binding var dialog: SettingsDialog?
  let row: SettingsAccountRow
  let selected: Bool

  private var t: Translator { model.t }
  private var optimisticPending: Bool { row.id.hasPrefix("pending:") }
  private var subscription: JSONValue? { row.account["subscription"] }
  private var attempt: JSONValue? { model.accountPool?["loginAttempts"]?[row.id] }
  private var attemptFailed: Bool { attempt?["status"]?.string == "failed" }
  private var loginPendingHere: Bool { controller.loginPendingId == row.id }

  private var title: String {
    SettingsValue.nonEmpty(subscription?["email"])
      ?? SettingsValue.nonEmpty(row.account["label"])
      ?? t("settings.accounts.defaultTitle")
  }

  private var status: String {
    if optimisticPending { return t("settings.accounts.statusAdding") }
    if subscription?["usable"]?.bool == true { return t("settings.accounts.statusReady") }
    if SettingsValue.truthy(subscription?["expired"]) { return t("settings.accounts.statusExpired") }
    return t("settings.accounts.statusSignInRequired")
  }

  private var usageLabel: String {
    if optimisticPending { return t("settings.accounts.savingAccount") }
    let usage = subscription?["usage"]
    if let remaining = SettingsValue.number(usage?["remainingPercent"]) {
      return t("settings.accounts.remaining", [
        "period": usage?["period"]?.string ?? "",
        "percent": SettingsValue.roundHalfUp(remaining),
      ])
    }
    return t("settings.accounts.usageUnavailable")
  }

  private var detailLine: String {
    let email = SettingsValue.nonEmpty(subscription?["email"])
    let label = SettingsValue.nonEmpty(row.account["label"])
    let prefix = (email != nil && label != nil) ? "\(label ?? "") · " : ""
    var tokenHours = ""
    if let hours = SettingsValue.number(subscription?["expiresInHours"]) {
      tokenHours = t("settings.accounts.tokenHours", ["hours": SettingsValue.numberText(hours)])
    }
    return "\(prefix)\(status)\(tokenHours) · \(usageLabel)"
  }

  private var loginDisabled: Bool {
    if optimisticPending || row.account["state"]?.string != "active" { return true }
    if attempt?["retryable"]?.bool == false { return true }
    if subscription?["usable"]?.bool == true && !attemptFailed { return true }
    return loginPendingHere
  }

  private var removeDisabled: Bool {
    if optimisticPending || row.account["state"]?.string == "revoked" { return true }
    if attempt?["retryable"]?.bool == false || attempt?["removable"]?.bool == false { return true }
    return loginPendingHere
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Image(systemName: "person").font(.system(size: 12)).foregroundStyle(.secondary)
          Text(title).font(.system(size: 13, weight: .semibold))
          if selected { Badge(t("settings.accounts.selectedBadge"), tone: .accent) }
        }
        Text(detailLine)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if attemptFailed, let error = SettingsValue.nonEmpty(attempt?["error"]) {
          Text(error)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      HStack(spacing: 6) {
        selectButton
        SettingsButton(
          title: t("settings.accounts.login"),
          systemImage: "arrow.right.circle",
          variant: .ghost,
          disabled: loginDisabled
        ) {
          startLogin()
        }
        SettingsButton(
          title: t("settings.accounts.remove"),
          systemImage: "trash",
          variant: .ghost,
          disabled: removeDisabled
        ) {
          dialog = .removeAccount(row.id)
        }
      }
      .controlSize(.small)
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(optimisticPending ? 0.65 : 1)
  }

  private var selectButton: some View {
    SettingsButton(
      title: selected ? t("settings.accounts.selectedBadge") : t("settings.accounts.select"),
      systemImage: "checkmark",
      variant: selected ? .secondary : .ghost,
      disabled: optimisticPending
    ) {
      let accountId = row.id
      model.perform(t("app.action.switchChatgptAccount")) { api in
        try await api.setChatGptAccountSelection(accountId)
      }
    }
    .accessibilityLabel(
      selected
        ? t("settings.accounts.selectedAria", ["name": title])
        : t("settings.accounts.selectAria", ["name": title])
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func startLogin() {
    let name = SettingsValue.nonEmpty(row.account["label"]) ?? t("settings.accounts.defaultTitle")
    controller.startLogin(accountId: row.id, name: name, hadFailedAttempt: attemptFailed, model: model)
  }
}
