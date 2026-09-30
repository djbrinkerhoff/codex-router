import ControlCenterCore
import SwiftUI

/// "Image reading": the bridge switch, reader and effort pickers, and the
/// local reader cards.
struct LocalVisionSection: View {
  @EnvironmentObject private var model: AppModel
  let d: LocalDerived
  /// The bridge switch, settled against the router.
  let visionEnabled: Bool
  let onToggleVision: (Bool) -> Void

  private var bridgeMissing: Bool { d.bridge == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: model.t("local.vision.title"), description: model.t("local.vision.description"))
      settings
      if d.readerDownloadActive { downloadProgress }
      if d.localReaders.isEmpty {
        EmptyStateView(title: model.t("local.vision.emptyTitle"), message: model.t("local.vision.emptyBody"))
      } else {
        CardGrid(minimum: 280) {
          ForEach(Array(d.localReaders.enumerated()), id: \.offset) { _, reader in
            LocalReaderCard(reader: reader, d: d)
          }
        }
      }
    }
    .panelStyle(padding: 14)
  }

  // MARK: Settings

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.t("local.vision.readTitle")).font(.system(size: 13, weight: .semibold))
          Text(model.t("local.vision.readDetail"))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        LocalSwitch(
          isOn: visionEnabled,
          label: model.t("local.vision.enableAria"),
          disabled: bridgeMissing,
          onChange: onToggleVision
        )
      }
      HStack(alignment: .top, spacing: 16) {
        readerPicker
        effortPicker
      }
      resolvedNotice
    }
  }

  private var readerPicker: some View {
    let chatgpt = d.engines.filter { $0.group == .chatgpt }
    let providers = d.engines.filter { $0.group == .provider }
    return VStack(alignment: .leading, spacing: 4) {
      Text(model.t("local.vision.reader")).font(.system(size: 12, weight: .medium))
      LocalPicker(
        title: model.t("local.vision.reader"),
        selection: d.selectedEngine,
        disabled: bridgeMissing,
        onSelect: { next in
          LocalActions.run(model, model.t("local.action.changeReader")) { api in
            try await api.setVisionBridgeEngine(next)
          }
        }
      ) {
        Text(model.t("local.vision.automatic")).tag("auto")
        if !chatgpt.isEmpty {
          Section(model.t("local.engineGroup.chatgpt")) {
            ForEach(chatgpt) { engine in Text(engine.displayName).tag(engine.slug) }
          }
        }
        if !providers.isEmpty {
          Section(model.t("local.engineGroup.providers")) {
            ForEach(providers) { engine in Text(engine.displayName).tag(engine.slug) }
          }
        }
        if let local = d.bridge?["local"], local.truthy {
          Text(model.t("local.vision.localOption", ["model": localModelName(local)])).tag("local")
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func localModelName(_ local: JSONValue) -> String {
    local["model"]?.text ?? model.t("local.vision.localFallback")
  }

  private var effortPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.t("local.vision.effort")).font(.system(size: 12, weight: .medium))
      LocalPicker(
        title: model.t("local.vision.effort"),
        selection: d.bridge?["effort"]?.text ?? "default",
        disabled: bridgeMissing,
        onSelect: { next in
          LocalActions.run(model, model.t("local.action.changeEffort")) { api in
            try await api.setVisionBridgeEffort(next)
          }
        }
      ) {
        Text(model.t("local.vision.readerDefault")).tag("default")
        ForEach(d.effortOptions, id: \.self) { effort in
          Text(Format.effortLabel(effort, model.t)).tag(effort)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var resolvedNotice: some View {
    let resolved = (d.bridge?["resolvedEngine"]).truthy
    let name = d.bridge?["resolvedEngineName"]?.text
    let message = name.map { model.t("local.vision.willTranscribe", ["name": $0]) } ?? model.t("local.vision.connectBody")
    return InlineNotice(
      tone: resolved ? .success : .warning,
      title: resolved ? model.t("local.vision.resolved") : model.t("local.vision.noReader"),
      message: message
    )
  }

  private var downloadProgress: some View {
    let download = d.bridge?["download"]
    return LocalDownloadProgress(
      tag: download?["tag"]?.string,
      percent: download?["percent"]?.double,
      detail: LocalSupport.or(model.t.backend(download?["detail"]?.string), model.t("local.vision.downloadingReader"))
    )
  }
}

/// One local image reader (`reader-card`).
private struct LocalReaderCard: View {
  @EnvironmentObject private var model: AppModel
  let reader: JSONValue
  let d: LocalDerived

  private var tag: String { reader["tag"]?.string ?? "" }

  private var active: Bool {
    d.bridge?["engine"]?.string == "local" && d.bridge?["local"]?["model"]?.string == tag
  }

  private var title: String {
    reader["label"]?.text ?? reader["displayName"]?.text ?? tag
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      Text(LocalSupport.or(model.t.backend(reader["note"]?.string), model.t("local.vision.defaultNote")))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      score
      footer
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border))
  }

  private var header: some View {
    let accuracy = LocalSupport.or(model.t.backend(reader["accuracy"]?.string), model.t("local.vision.untested"))
    let summary = "\(Format.bytesGb(reader["sizeGb"]?.double, model.t)) · \(accuracy)"
    return HStack(spacing: 10) {
      BrandLogo(brand: LocalSupport.brand(for: reader), size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if active {
        Badge(model.t("local.badge.active"), tone: .success)
      } else if reader["recommended"].truthy {
        Badge(model.t("local.badge.recommended"), tone: .accent)
      }
    }
  }

  @ViewBuilder
  private var score: some View {
    if let percent = reader["measured"]?["percent"]?.double {
      let key = reader["measuredLocally"].truthy ? "local.vision.referenceScoreLocal" : "local.vision.referenceScore"
      Text(model.t(key, ["percent": Int(percent.rounded())]))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if reader["installed"].truthy {
        Button {
          LocalActions.run(model, model.t("local.action.useReader", ["tag": tag])) { api in
            try await api.useLocalVisionModel(tag)
          }
        } label: {
          Label(active ? model.t("local.vision.inUse") : model.t("local.vision.useReader"), systemImage: "eye")
        }
        .buttonStyle(.borderless)
        .disabled(active)
        Button {
          LocalActions.run(model, model.t("local.action.measureReader", ["tag": tag])) { api in
            try await api.benchmarkVisionModel(tag)
          }
        } label: {
          Label(model.t("local.vision.measure"), systemImage: "gauge")
        }
        .buttonStyle(.borderless)
      } else {
        Button {
          LocalActions.run(model, model.t("local.action.downloadReader", ["tag": tag]), startsDownload: true) { api in
            try await api.downloadVisionModel(tag)
          }
        } label: {
          Label(model.t("local.vision.download"), systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .disabled(d.readerDownloadActive || reader["fits"]?.bool == false)
      }
      Spacer(minLength: 0)
    }
  }
}
