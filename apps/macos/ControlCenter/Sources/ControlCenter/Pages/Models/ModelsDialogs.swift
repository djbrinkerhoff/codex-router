import ControlCenterCore
import SwiftUI

// The Models page's dialogs, presented as sheets: credential entry, custom
// endpoints, models by name, and the confirmations. Ports `CredentialDialog`,
// `NamedModelDialog`, `CustomEndpointDialog`, and the inline `Dialog`s of
// `renderConnectionDialogs`.

// MARK: - Credential

/// API-key entry. The value lives only in the `SecureField` until submit: it
/// is handed to the caller once, and the field is cleared before the router
/// call even starts. It is never logged, stored, or echoed.
struct ModelsCredentialSheet: View {
  @EnvironmentObject private var model: AppModel
  let provider: ModelsSetup
  let onSave: (ModelsSetup, String) -> Void
  let onClose: () -> Void
  @State private var credential = ""
  @FocusState private var focused: Bool

  private var title: String {
    if provider.configured {
      return model.t("models.credential.replace", ["name": provider.displayName])
    }
    let name = ModelsLogic.nonEmpty(provider.displayName, or: model.t("models.credential.provider"))
    return model.t("models.credential.connect", ["name": name])
  }

  private var fieldLabel: String {
    ModelsLogic.nonEmpty(model.t.backend(provider.credentialLabel), or: model.t("models.credential.apiKey"))
  }

  private var canSave: Bool {
    !ModelsLogic.trimmed(credential).isEmpty
  }

  var body: some View {
    ModelsDialogFrame(title: title, description: model.t("models.credential.description")) {
      HStack(spacing: 10) {
        ProviderLogo(providerId: provider.id, displayName: provider.displayName, size: 32)
        VStack(alignment: .leading, spacing: 1) {
          Text(provider.displayName).font(.system(size: 13.5, weight: .semibold))
          Text(provider.id)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(fieldLabel).font(.system(size: 12, weight: .medium))
        SecureField(model.t("models.credential.placeholder"), text: $credential)
          .textFieldStyle(.roundedBorder)
          .focused($focused)
          .onSubmit(submit)
      }
      ModelsNoteRow(systemImage: "link", text: model.t("models.credential.note"))
      HStack {
        Spacer()
        Button(model.t("models.add.cancel"), action: close)
          .keyboardShortcut(.cancelAction)
        Button(model.t("models.credential.save"), action: submit)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
      }
    }
    .onAppear { focused = true }
    .onDisappear { credential = "" }
  }

  private func submit() {
    guard canSave else { return }
    let secret = credential
    credential = ""
    onClose()
    onSave(provider, secret)
  }

  private func close() {
    credential = ""
    onClose()
  }
}

// MARK: - Model by name

struct ModelsNamedModelSheet: View {
  @EnvironmentObject private var model: AppModel
  let provider: ModelsSetup
  let onSave: (ModelsSetup, String) -> Void
  let onClose: () -> Void
  @State private var modelId = ""

  private var trimmedId: String { ModelsLogic.trimmed(modelId) }

  var body: some View {
    let shown = trimmedId.isEmpty ? model.t("customEndpoint.named.placeholder") : trimmedId
    ModelsDialogFrame(
      title: model.t("customEndpoint.named.title"),
      description: model.t("customEndpoint.named.description")
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text(model.t("models.details.modelId")).font(.system(size: 12, weight: .medium))
        TextField("provider-model-id", text: $modelId)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .onSubmit(submit)
      }
      ModelsNoteRow(
        systemImage: "link",
        text: model.t("customEndpoint.named.note", ["model": "\(provider.id)/\(shown)"])
      )
      HStack {
        Spacer()
        Button(model.t("models.add.cancel"), action: close)
          .keyboardShortcut(.cancelAction)
        Button(model.t("customEndpoint.named.add"), action: submit)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(trimmedId.isEmpty)
      }
    }
  }

  private func submit() {
    let id = trimmedId
    guard !id.isEmpty else { return }
    modelId = ""
    onClose()
    onSave(provider, id)
  }

  private func close() {
    modelId = ""
    onClose()
  }
}

// MARK: - Custom endpoint

struct ModelsEndpointSheet: View {
  @EnvironmentObject private var model: AppModel
  let editing: ModelsSetup?
  let onSave: (ModelsEndpointInput, ModelsSetup?) -> Void
  let onClose: () -> Void
  @State private var displayName: String
  @State private var baseUrl: String
  @State private var adapter: RouterControl.EndpointAdapter
  @State private var credential = ""

  init(
    editing: ModelsSetup?,
    onSave: @escaping (ModelsEndpointInput, ModelsSetup?) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.editing = editing
    self.onSave = onSave
    self.onClose = onClose
    _displayName = State(initialValue: editing?.displayName ?? "")
    _baseUrl = State(initialValue: editing?.baseUrl ?? "")
    _adapter = State(initialValue: editing?.adapter == "openai-responses" ? .openaiResponses : .openaiChat)
  }

  private var urlValid: Bool {
    guard let url = URL(string: ModelsLogic.trimmed(baseUrl)),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return false }
    return !(url.host ?? "").isEmpty
  }

  private var ready: Bool {
    !ModelsLogic.trimmed(displayName).isEmpty && urlValid
  }

  private var title: String {
    if let editing { return model.t("customEndpoint.form.editTitle", ["name": editing.displayName]) }
    return model.t("customEndpoint.form.addTitle")
  }

  private var descriptionText: String {
    if let editing { return model.t("customEndpoint.form.editDescription", ["prefix": "\(editing.id)/"]) }
    return model.t("customEndpoint.form.addDescription")
  }

  private var keyPlaceholder: String {
    guard let editing else { return model.t("customEndpoint.form.keylessLocal") }
    return editing.hasKey ? model.t("customEndpoint.form.keepKey") : model.t("customEndpoint.form.stayKeyless")
  }

  var body: some View {
    ModelsDialogFrame(title: title, description: descriptionText) {
      field(model.t("customEndpoint.form.name")) {
        TextField(model.t("customEndpoint.form.namePlaceholder"), text: $displayName)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .onChange(of: displayName) { value in
            if value.count > 120 { displayName = String(value.prefix(120)) }
          }
      }
      field(model.t("customEndpoint.form.baseUrl")) {
        TextField("https://api.example.com/v1", text: $baseUrl)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
      }
      field(model.t("customEndpoint.form.format")) {
        Picker(model.t("customEndpoint.form.format"), selection: $adapter) {
          Text("Chat Completions (/chat/completions)").tag(RouterControl.EndpointAdapter.openaiChat)
          Text("Responses (/responses)").tag(RouterControl.EndpointAdapter.openaiResponses)
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      field(model.t("models.credential.apiKey")) {
        SecureField(keyPlaceholder, text: $credential)
          .textFieldStyle(.roundedBorder)
      }
      ModelsNoteRow(systemImage: "link", text: model.t("customEndpoint.form.keyNote"))
      HStack {
        Spacer()
        Button(model.t("models.add.cancel"), action: close)
          .keyboardShortcut(.cancelAction)
        Button(
          editing != nil ? model.t("customEndpoint.form.save") : model.t("customEndpoint.form.saveChoose"),
          action: submit
        )
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!ready)
      }
    }
    .onDisappear { credential = "" }
  }

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.system(size: 12, weight: .medium))
      content()
    }
  }

  private func submit() {
    guard ready else { return }
    let hasCredential = !ModelsLogic.trimmed(credential).isEmpty
    let endpoint = ModelsEndpointInput(
      displayName: ModelsLogic.trimmed(displayName),
      baseUrl: ModelsLogic.trimmed(baseUrl),
      adapter: adapter,
      credential: hasCredential ? credential : nil
    )
    let target = editing
    credential = ""
    onClose()
    onSave(endpoint, target)
  }

  private func close() {
    credential = ""
    onClose()
  }
}

// MARK: - Notices and confirmations

/// A saved endpoint whose first live check failed. The endpoint is kept, so
/// this says what happened and offers the two ways forward.
struct ModelsEndpointNoticeSheet: View {
  @EnvironmentObject private var model: AppModel
  let displayName: String
  let reason: String
  let onClose: () -> Void
  let onNameModel: () -> Void

  var body: some View {
    let name = ModelsLogic.nonEmpty(displayName, or: model.t("customEndpoint.fallbackName"))
    ModelsDialogFrame(
      title: model.t("customEndpoint.notice.title", ["name": name]),
      description: model.t("customEndpoint.notice.description")
    ) {
      ModelsNoteRow(
        systemImage: "checkmark.shield",
        text: "\(model.t.backend(reason)) \(model.t("customEndpoint.notice.help"))"
      )
      HStack {
        Spacer()
        Button(model.t("models.config.close"), action: onClose)
          .keyboardShortcut(.cancelAction)
        Button(action: onNameModel) {
          Label(model.t("customEndpoint.named.title"), systemImage: "plus")
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
  }
}

struct ModelsConfigurationSheet: View {
  @EnvironmentObject private var model: AppModel
  let provider: ModelsSetup
  let onClose: () -> Void

  var body: some View {
    let name = ModelsLogic.nonEmpty(provider.displayName, or: model.t("models.credential.provider"))
    ModelsDialogFrame(
      title: model.t("models.config.title", ["name": name]),
      description: model.t("models.config.description")
    ) {
      ModelsNoteRow(
        systemImage: "checkmark.shield",
        text: ModelsLogic.nonEmpty(model.t.backend(provider.configurationNote), or: model.t("models.config.run"))
      )
      HStack {
        Spacer()
        Button(model.t("models.config.close"), action: onClose)
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

struct ModelsDisconnectSheet: View {
  @EnvironmentObject private var model: AppModel
  let provider: ModelsSetup
  let onClose: () -> Void
  let onConfirm: (ModelsSetup) -> Void

  private var warning: String {
    if provider.generic { return model.t("customEndpoint.removeBody") }
    if provider.id == "antigravity-oauth" { return model.t("models.disconnect.antigravity") }
    return model.t("models.disconnect.env")
  }

  var body: some View {
    ModelsDialogFrame(
      title: model.t("models.disconnect.title"),
      description: model.t("models.disconnect.description")
    ) {
      ModelsNoteRow(systemImage: "checkmark.shield", text: warning)
      HStack {
        Spacer()
        Button(model.t("models.disconnect.cancel"), action: onClose)
          .keyboardShortcut(.cancelAction)
        Button(role: .destructive) {
          onClose()
          onConfirm(provider)
        } label: {
          Label(model.t("models.disconnect.confirm"), systemImage: "trash")
        }
      }
    }
  }
}

/// Deleting a locally curated model is not undoable from here -- the overlay
/// entry and its metadata go, and re-adding it means curating the model again
/// -- so it is confirmed the way disconnecting a provider is.
struct ModelsRemoveLocalSheet: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let onClose: () -> Void
  let onConfirm: (ModelsRoute) -> Void

  var body: some View {
    ModelsDialogFrame(
      title: model.t("models.local.removeTitle"),
      description: model.t("models.local.removeDescription", ["name": route.displayName])
    ) {
      // Name the slug: the operator may have curated several near-identical
      // ids on one provider, and the display name alone does not separate
      // them.
      ModelsNoteRow(systemImage: "checkmark.shield", text: model.t("models.local.removeBody", ["slug": route.slug]))
      HStack {
        Spacer()
        Button(model.t("models.disconnect.cancel"), action: onClose)
          .keyboardShortcut(.cancelAction)
        Button(role: .destructive) {
          onClose()
          onConfirm(route)
        } label: {
          Label(model.t("models.local.removeConfirm"), systemImage: "trash")
        }
      }
    }
  }
}
