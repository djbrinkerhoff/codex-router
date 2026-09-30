import AppKit
import ControlCenterCore
import SwiftUI

// Constants, logos, and copy helpers for the Harness page, ported from the
// top and bottom of `HarnessPage.tsx`.

enum HarnessSupport {
  /// The six clients that predate the shared publisher keep their order; the
  /// five document-configured harnesses follow, so an existing user's rows do
  /// not move under them on upgrade.
  static let clientOrder: [String] = [
    "openclaw", "cursor", "claude", "gemini", "dsh", "codex",
    "opencode", "pi", "omp", "commandcode", "hermes",
  ]

  static let terminalOnlyClients: Set<String> = ["opencode", "pi", "omp", "commandcode", "hermes"]

  /// Operation labels that mean the Cursor row is mid-setup. The English
  /// names are the ones the router's own operation events carry.
  static let cursorOperationActions: Set<String> = [
    "connectCursor",
    "disconnectCursor",
    "disconnectHarness",
    "Connect Cursor",
    "Disconnect Cursor",
    "prepareCursorTunnel",
    "Install Cloudflare connector",
    "Sign in to Cloudflare Tunnel",
    "Configure Cursor",
  ]

  static func bridge(for id: String, in snapshot: JSONValue?) -> JSONValue? {
    let bridgeId: String?
    switch id {
    case "claude": bridgeId = "anthropic"
    case "cursor", "gemini": bridgeId = id
    default: bridgeId = nil
    }
    guard let bridgeId else { return nil }
    return snapshot?["bridges"]?.items.first { $0["id"]?.string == bridgeId }
  }

  static func modelFact(_ harness: JSONValue, modelCount: Int, _ t: Translator) -> (label: String, title: String) {
    let configured = harness["configured"].truthy
    if harness["id"]?.string == "cursor" {
      return configured
        ? (String(modelCount), t("harness.fact.available", ["count": modelCount]))
        : ("—", t("harness.fact.readyAfterSetup"))
    }
    return configured
      ? (String(modelCount), t("harness.fact.published", ["count": modelCount]))
      : ("—", t("harness.fact.notPublished"))
  }

  static func cursorTunnelHelp(_ harness: JSONValue, _ t: Translator) -> String {
    let tunnel = harness["tunnel"]
    if !(tunnel?["binaryInstalled"]).truthy { return t("harness.cursor.helpInstall") }
    if !(tunnel?["loggedIn"]).truthy { return t("harness.cursor.helpAuthorize") }
    return t("harness.cursor.helpPublish")
  }

  static func hint(_ harness: JSONValue, _ t: Translator) -> String {
    let id = harness["id"]?.string ?? ""
    if id == "cursor" { return t("harness.hint.cursor") }
    if terminalOnlyClients.contains(id) { return t("harness.hint.terminalOnly") }
    if id == "codex" { return t("harness.hint.codex") }
    return t("harness.hint.default", ["name": harness["displayName"]?.string ?? id])
  }
}

// MARK: Client logos

/// A client mark: the checkout's `apps/control-center/src/assets/clients`
/// (or `Brand/clients` in the packaged app), plus the few provider marks a
/// client shares with its maker. Anything that will not load falls back to a
/// monogram, so a missing asset never blanks a row.
enum HarnessLogos {
  struct Spec {
    let light: String
    var dark: String?
    /// `true` for artwork that keeps its colors, `false` for a mask tinted
    /// with the surrounding text color.
    let artwork: Bool
    var provider = false
  }

  static let specs: [String: Spec] = [
    "cursor": Spec(light: "cursor.svg", dark: "cursor-dark.svg", artwork: true),
    "dsh": Spec(light: "deepseek-harness.svg", dark: nil, artwork: false),
    "codex": Spec(light: "codex-light.svg", dark: "codex-dark.svg", artwork: true),
    "claude": Spec(light: "claude.svg", dark: nil, artwork: true),
    "gemini": Spec(light: "gemini.svg", dark: nil, artwork: true, provider: true),
    "openclaw": Spec(light: "openclaw.svg", dark: nil, artwork: true),
    "opencode": Spec(light: "opencode.png", dark: nil, artwork: true, provider: true),
    "pi": Spec(light: "pi.svg", dark: nil, artwork: true),
    // omp's official mark is drawn in near-white for a dark ground. Painting
    // it in the surrounding text color keeps it legible in both themes.
    "omp": Spec(light: "omp.svg", dark: nil, artwork: false),
    "commandcode": Spec(light: "commandcode.svg", dark: nil, artwork: true, provider: true),
    "hermes": Spec(light: "nousresearch.png", dark: nil, artwork: false, provider: true),
  ]

  static let clientsDirectory: URL? = {
    if let packaged = Bundle.main.resourceURL?.appendingPathComponent("Brand/clients", isDirectory: true),
      FileManager.default.fileExists(atPath: packaged.path)
    {
      return packaged
    }
    return ProviderBranding.directory?
      .deletingLastPathComponent()
      .appendingPathComponent("clients", isDirectory: true)
  }()

  @MainActor private static var cache: [String: NSImage] = [:]

  /// The image for one client and theme, with its rendering mode.
  @MainActor
  static func logo(for id: String, dark: Bool) -> (image: NSImage, artwork: Bool)? {
    guard let spec = specs[id] else { return nil }
    let file = dark ? (spec.dark ?? spec.light) : spec.light
    let directory = spec.provider ? ProviderBranding.directory : clientsDirectory
    guard let directory else { return nil }
    let url = directory.appendingPathComponent(file)
    let key = url.path
    if let cached = cache[key] { return (cached, spec.artwork) }
    guard let image = NSImage(contentsOf: url) else { return nil }
    cache[key] = image
    return (image, spec.artwork)
  }
}

/// A client's mark in its row.
struct HarnessMark: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let id: String
  let name: String
  var size: CGFloat = 34

  var body: some View {
    // The scheme is read so the mark redraws when the appearance changes.
    let dark = model.isDark || colorScheme == .dark
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .fill(Color.secondary.opacity(0.10))
      mark(dark: dark)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func mark(dark: Bool) -> some View {
    if let logo = HarnessLogos.logo(for: id, dark: dark) {
      if logo.artwork {
        Image(nsImage: logo.image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .padding(size * 0.14)
      } else {
        Image(nsImage: logo.image)
          .renderingMode(.template)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(Color.primary)
          .padding(size * 0.18)
      }
    } else {
      Text(monogram)
        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
    }
  }

  private var monogram: String {
    let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
    let joined = letters.joined()
    return joined.isEmpty ? String(id.prefix(2)).uppercased() : joined
  }
}
