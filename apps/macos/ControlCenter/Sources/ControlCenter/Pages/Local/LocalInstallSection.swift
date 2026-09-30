import ControlCenterCore
import SwiftUI

/// "Install a model": the tag form, the active download, quick picks, and the
/// searchable Ollama catalog.
struct LocalInstallSection: View {
  @EnvironmentObject private var model: AppModel
  let d: LocalDerived
  @Binding var installRef: String
  @Binding var forceInstall: Bool
  @Binding var catalogQuery: String
  @Binding var expandedFamilies: Set<String>
  let onInstall: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: model.t("local.install.title"), description: model.t("local.install.description"))
      installForm
      Toggle(model.t("local.install.allowLarger"), isOn: $forceInstall)
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
      activeDownload
      if !d.quickPicks.isEmpty { quickPicks }
      if !d.catalogModels.isEmpty { catalog }
    }
    .panelStyle(padding: 14)
  }

  // MARK: Form

  private var trimmedRef: String {
    installRef.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var installForm: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(model.t("local.install.label")).font(.system(size: 12, weight: .medium))
      HStack(spacing: 8) {
        TextField("qwen3.5:9b", text: $installRef)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
          .onSubmit { if !trimmedRef.isEmpty { onInstall() } }
        Button {
          onInstall()
        } label: {
          Label(model.t("local.install.submit"), systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(trimmedRef.isEmpty)
      }
    }
  }

  @ViewBuilder
  private var activeDownload: some View {
    let download = d.local?["download"]
    if let status = download?["status"]?.text, status != "done" {
      LocalDownloadProgress(
        tag: download?["tag"]?.string,
        percent: download?["percent"]?.double,
        detail: model.t.backend(download?["detail"]?.text ?? status)
      )
    }
  }

  // MARK: Quick picks

  private var quickPicks: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(model.t("local.quick.title")).font(.system(size: 12.5, weight: .semibold))
        Text(model.t("local.quick.detail")).font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      CardGrid(minimum: 250) {
        ForEach(Array(d.quickPicks.enumerated()), id: \.offset) { _, pick in
          quickPick(pick)
        }
      }
    }
  }

  private func quickPick(_ pick: JSONValue) -> some View {
    let cloudOnly = pick["downloadable"]?.bool == false
    let fit = LocalSupport.or(model.t.backend(pick["fit"]?.string), model.t("local.quick.fitUnknown"))
    let summary = "\(Format.bytesGb(pick["sizeGb"]?.double, model.t)) · \(fit)"
    return Button {
      if let tag = pick["tag"]?.string { installRef = tag }
    } label: {
      HStack(spacing: 8) {
        BrandLogo(brand: LocalSupport.brand(for: pick), size: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(LocalSupport.modelName(pick)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 4)
        if cloudOnly {
          Badge(model.t("local.badge.cloudOnly"), tone: .neutral)
        } else if pick["recommended"].truthy {
          Badge(model.t("local.badge.recommended"), tone: .accent)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(cloudOnly)
  }

  // MARK: Catalog browser

  private var catalog: some View {
    let families = LocalSupport.groupCatalog(d.catalogModels, families: d.knownFamilies, query: catalogQuery)
    let tags = LocalSupport.visibleTagCount(families)
    let searching = !catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let summary = searching
      ? model.t("local.catalog.countMatches", ["families": families.count, "tags": tags])
      : model.t("local.catalog.countTags", ["families": families.count, "tags": tags])
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        SearchField(text: $catalogQuery, placeholder: model.t("local.catalog.searchPlaceholder"))
        Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      if families.isEmpty {
        EmptyStateView(
          systemImage: "magnifyingglass",
          title: model.t("local.catalog.emptyTitle"),
          message: model.t("local.catalog.emptyBody")
        )
      } else {
        VStack(spacing: 6) {
          ForEach(families) { family in
            LocalCatalogFamilyView(
              family: family,
              expanded: expandedFamilies.contains(family.id),
              allowOversized: forceInstall,
              onToggle: { toggle(family.id) },
              onSelect: { tag in installRef = tag }
            )
          }
        }
      }
    }
  }

  private func toggle(_ id: String) {
    if expandedFamilies.contains(id) {
      expandedFamilies.remove(id)
    } else {
      expandedFamilies.insert(id)
    }
  }
}

/// One collapsible family in the catalog browser.
private struct LocalCatalogFamilyView: View {
  @EnvironmentObject private var model: AppModel
  let family: LocalCatalogFamily
  let expanded: Bool
  let allowOversized: Bool
  let onToggle: () -> Void
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggle) {
        HStack(spacing: 10) {
          if let first = family.models.first {
            BrandLogo(brand: LocalSupport.brand(for: first), size: 28)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text(family.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(model.t("local.catalog.familyTags", [
              "count": family.models.count,
              "summary": LocalSupport.familySummary(family.models, model.t),
            ]))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(expanded ? .isSelected : [])
      if expanded {
        Divider()
        panel
      }
    }
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.05)))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border))
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let status = family.researchStatus {
        Text(researchLine(status))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let note = family.researchNote {
        Text(model.t.backend(note))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 0) {
        ForEach(Array(family.models.enumerated()), id: \.offset) { index, item in
          if index > 0 { Divider() }
          LocalCatalogModelRow(item: item, allowOversized: allowOversized) {
            onSelect(item["tag"]?.string ?? "")
          }
        }
      }
    }
    .padding(10)
  }

  private func researchLine(_ status: String) -> String {
    var line = model.t.backend(status)
    if !family.researchCapabilities.isEmpty {
      let capabilities = family.researchCapabilities.map { model.t.backend($0) }.joined(separator: " · ")
      line += " · \(capabilities)"
    }
    return line
  }
}

/// One tag inside a family (`CatalogModelRow`).
private struct LocalCatalogModelRow: View {
  @EnvironmentObject private var model: AppModel
  let item: JSONValue
  let allowOversized: Bool
  let onSelect: () -> Void

  var body: some View {
    let downloadable = item["downloadable"]?.bool != false
    let tooLarge = item["fit"]?.string == "too-large" || item["diskFit"]?.string == "too-large"
    let tight = item["fit"]?.string == "tight" || item["diskFit"]?.string == "tight"
    let fitLabel: String
    if !downloadable {
      fitLabel = model.t("local.fit.cloudOnly")
    } else if tooLarge {
      fitLabel = model.t("local.fit.tooLarge")
    } else if tight {
      fitLabel = model.t("local.fit.memoryTight")
    } else {
      fitLabel = model.t("local.fit.fitsMachine")
    }
    let tone: Tone
    if !downloadable {
      tone = .neutral
    } else if tooLarge {
      tone = .danger
    } else if item["fit"]?.string == "tight" {
      tone = .warning
    } else {
      tone = .success
    }
    return HStack(spacing: 10) {
      BrandLogo(brand: LocalSupport.brand(for: item), size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(LocalSupport.modelName(item)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Badge(fitLabel, tone: tone)
      Button(action: onSelect) {
        Label(model.t("local.fit.select"), systemImage: "arrow.down.circle")
      }
      .buttonStyle(.borderless)
      .disabled(!downloadable || (tooLarge && !allowOversized))
    }
    .padding(.vertical, 6)
  }

  private var detail: String {
    var text = item["tag"]?.string ?? ""
    if let sizeValue = item["sizeGb"], !sizeValue.isNull {
      text += " · \(Format.bytesGb(sizeValue.double, model.t))"
    }
    if let context = item["context"]?.double, context != 0 {
      text += model.t("local.fit.contextSuffix", ["count": Format.compactNumber(context, model.t)])
    }
    return text
  }
}
