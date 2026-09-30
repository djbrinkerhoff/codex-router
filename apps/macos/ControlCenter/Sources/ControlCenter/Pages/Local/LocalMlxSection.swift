import ControlCenterCore
import SwiftUI

/// The Qwen 3.8 27B MLX installer card.
struct LocalMlxSection: View {
  @EnvironmentObject private var model: AppModel
  let d: LocalDerived

  private var slug: String {
    d.mlx?["model"]?["slug"]?.text ?? "lmstudio/qwen38-27b-uncensored-mlx"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: "Qwen 3.8 27B · MLX", description: model.t("local.mlx.description")) {
        statusBadge
      }
      installLayout
      Divider()
      notices
    }
    .panelStyle(padding: 14)
  }

  // MARK: Status badge

  private var statusBadge: some View {
    let tone: Tone = d.mlxReady ? .success : d.mlxActive ? .accent : d.mlxStatus == "error" ? .danger : .neutral
    return Badge(statusText, tone: tone)
  }

  private var statusText: String {
    if d.mlxReady { return model.t("local.mlx.inCodex") }
    if !d.mlxSupported { return model.t("local.mlx.unsupported") }
    if d.mlxPublished { return model.t("local.mlx.repairNeeded") }
    if d.mlxActive { return LocalSupport.stageLabel(d.mlxStatus, model.t) }
    if d.mlxStatus == "error" { return model.t("local.mlx.needsAttention") }
    return model.t("local.mlx.notInstalled")
  }

  // MARK: Copy and actions

  private var installLayout: some View {
    HStack(alignment: .top, spacing: 20) {
      copyColumn
      actionColumn
        .frame(width: 240, alignment: .leading)
    }
  }

  private var copyColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Qwen3.8-27B-Uncensored · 4-bit MLX").font(.system(size: 13, weight: .semibold))
      oneClickParagraph
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      prerequisites
      installHint(d.mlx?["prerequisites"]?["lms"])
      installHint(d.mlx?["prerequisites"]?["uvx"])
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var oneClickParagraph: Text {
    let leadText = model.t("local.mlx.oneClick") + " "
    let lead = Text(verbatim: leadText)
    let code = Text(verbatim: slug).font(.system(size: 12, design: .monospaced))
    let tail = Text(verbatim: model.t("local.mlx.oneClickSuffix"))
    return lead + code + tail
  }

  private var prerequisites: some View {
    let lmsReady = (d.mlx?["prerequisites"]?["lms"]?["available"]).truthy
    let uvxReady = (d.mlx?["prerequisites"]?["uvx"]?["available"]).truthy
    let loopback = (d.mlx?["runtime"]?["loopbackReachable"]).truthy
    return VStack(alignment: .leading, spacing: 4) {
      prerequisite(
        ready: lmsReady,
        text: "\(model.t("local.mlx.lmsPrefix")) \(lmsReady ? model.t("local.mlx.ready") : model.t("local.mlx.installedDuringSetup"))"
      )
      prerequisite(
        ready: uvxReady,
        text: "\(model.t("local.mlx.uvxPrefix")) \(uvxReady ? model.t("local.mlx.ready") : model.t("local.mlx.installedDuringSetup"))"
      )
      prerequisite(ready: loopback, text: model.t("local.mlx.loopbackOnly"))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.t("local.mlx.prerequisitesAria"))
  }

  private func prerequisite(ready: Bool, text: String) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(ready ? Palette.success : Color.secondary.opacity(0.4))
        .frame(width: 7, height: 7)
      Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func installHint(_ prerequisite: JSONValue?) -> some View {
    if !(prerequisite?["available"]).truthy, let hint = prerequisite?["installHint"]?.string, !hint.isEmpty {
      Text(model.t.backend(hint))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actionColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      if d.mlxActive {
        Button {
          LocalActions.run(model, model.t("local.action.cancelMlx")) { api in try await api.cancelLocalMlx() }
        } label: {
          Text(model.t("local.mlx.cancel"))
        }
        .buttonStyle(.bordered)
      } else {
        Button {
          LocalActions.run(model, model.t("local.action.startMlx"), startsDownload: true) { api in
            try await api.installLocalMlx()
          }
        } label: {
          Label(installLabel, systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(d.mlxReady || !d.mlxSupported || d.ollamaMutationActive)
      }
      Text(model.t("local.mlx.consent"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var installLabel: String {
    if d.mlxReady { return model.t("local.mlx.installed") }
    if d.mlxPublished { return model.t("local.mlx.repairAndReconnect") }
    if d.mlxStatus == "error" || d.mlxStatus == "cancelled" { return model.t("local.mlx.retryInstall") }
    return model.t("local.mlx.installAndAdd")
  }

  // MARK: Notices

  private var notices: some View {
    VStack(alignment: .leading, spacing: 10) {
      InlineNotice(tone: .warning, title: model.t("local.mlx.guardrailsTitle"), message: model.t("local.mlx.guardrailsBody"))
      if !d.mlxSupported {
        InlineNotice(
          tone: .warning,
          title: model.t("local.mlx.appleTitle"),
          message: LocalSupport.or(model.t.backend(d.mlx?["host"]?["reason"]?.string), model.t("local.mlx.appleBody"))
        )
      }
      if d.ollamaMutationActive && !d.mlxActive {
        InlineNotice(tone: .warning, title: model.t("local.mlx.waitTitle"), message: model.t("local.mlx.waitBody"))
      }
      if d.mlxActive {
        LocalDownloadProgress(
          tag: LocalSupport.stageLabel(d.mlxStatus, model.t),
          percent: d.mlx?["operation"]?["percent"]?.double,
          detail: LocalSupport.or(model.t.backend(d.mlx?["operation"]?["detail"]?.string), model.t("local.mlx.working")),
          indeterminate: d.mlx?["operation"]?["progressMode"]?.string == "indeterminate"
        )
      }
      if d.mlxStatus == "error" {
        InlineNotice(tone: .danger, title: model.t("local.mlx.errorTitle"), message: errorMessage)
      }
      if d.mlxStatus == "cancelled" {
        InlineNotice(tone: .warning, title: model.t("local.mlx.cancelledTitle"), message: model.t("local.mlx.cancelledBody"))
      }
      if d.mlxReady {
        InlineNotice(tone: .success, title: model.t("local.mlx.readyTitle"), message: "\(model.t("local.mlx.readyBody")) \(slug).")
      }
    }
  }

  private var errorMessage: String {
    let error = model.t.backend(d.mlx?["operation"]?["error"]?.string)
    if !error.isEmpty { return error }
    let detail = model.t.backend(d.mlx?["operation"]?["detail"]?.string)
    if !detail.isEmpty { return detail }
    return model.t("local.mlx.errorBody")
  }
}
