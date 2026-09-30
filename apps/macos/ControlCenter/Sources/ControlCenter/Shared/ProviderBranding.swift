import AppKit
import ControlCenterCore
import SwiftUI

/// Provider and model marks, ported from `provider-branding.tsx`. The logo
/// files are the renderer's own (`apps/control-center/src/assets`), copied
/// into the app bundle by the build so both windows show the same artwork.
struct ProviderBrand: Equatable {
  let key: String
  let name: String
  let shortName: String
  let color: String
  var logo: String?
  /// Artwork logos keep their colors; mask logos are tinted with `color`.
  var artwork = false
}

enum ProviderBranding {
  static let brands: [String: ProviderBrand] = [
    "antigravity": ProviderBrand(key: "antigravity", name: "Antigravity", shortName: "AG", color: "#4285f4", logo: "antigravity.png", artwork: true),
    "anthropic": ProviderBrand(key: "anthropic", name: "Anthropic", shortName: "A", color: "#d97757", logo: "anthropic.png", artwork: true),
    "cerebras": ProviderBrand(key: "cerebras", name: "Cerebras", shortName: "C", color: "#f15a24", logo: "cerebras.png", artwork: true),
    "chutes": ProviderBrand(key: "chutes", name: "Chutes", shortName: "CH", color: "#42a875", logo: "chutes.svg"),
    "cline": ProviderBrand(key: "cline", name: "Cline", shortName: "CL", color: "#5b6df2", logo: "cline.png", artwork: true),
    "commandcode": ProviderBrand(key: "commandcode", name: "Command Code", shortName: "CC", color: "#8c4edd", logo: "commandcode.svg", artwork: true),
    "cognition": ProviderBrand(key: "cognition", name: "Devin", shortName: "DV", color: "#0d98d4", logo: "cognition.svg", artwork: true),
    "deepseek": ProviderBrand(key: "deepseek", name: "DeepSeek", shortName: "DS", color: "#4d6bfe", logo: "deepseek.png"),
    "deepreinforce": ProviderBrand(key: "deepreinforce", name: "Ornith", shortName: "OR", color: "#8f816b", logo: "deepreinforce.svg", artwork: true),
    "stealth": ProviderBrand(key: "stealth", name: "Stealth preview", shortName: "SP", color: "#3f4550", logo: "stealth.svg", artwork: true),
    "fireworks": ProviderBrand(key: "fireworks", name: "Fireworks AI", shortName: "FW", color: "#6720ff", logo: "fireworks.svg"),
    "github": ProviderBrand(key: "github", name: "GitHub", shortName: "GH", color: "#59636e", logo: "github-copilot.svg"),
    "gemini": ProviderBrand(key: "gemini", name: "Gemini", shortName: "GM", color: "#5684d1", logo: "gemini.svg", artwork: true),
    "google": ProviderBrand(key: "google", name: "Google", shortName: "G", color: "#4285f4", logo: "google.svg"),
    "groq": ProviderBrand(key: "groq", name: "Groq", shortName: "GQ", color: "#f43e01", logo: "groq.svg", artwork: true),
    "huggingface": ProviderBrand(key: "huggingface", name: "Hugging Face", shortName: "HF", color: "#d89b00", logo: "huggingface.svg"),
    "kimi": ProviderBrand(key: "kimi", name: "Kimi", shortName: "K", color: "#2f6bff", logo: "kimi.png", artwork: true),
    "kilo": ProviderBrand(key: "kilo", name: "Kilo", shortName: "KL", color: "#cfca00", logo: "kilo.svg", artwork: true),
    "lmstudio": ProviderBrand(key: "lmstudio", name: "LM Studio", shortName: "LM", color: "#654cdb", logo: "lmstudio.svg", artwork: true),
    "meta": ProviderBrand(key: "meta", name: "Meta", shortName: "M", color: "#0467df", logo: "meta.svg"),
    "minimax": ProviderBrand(key: "minimax", name: "MiniMax", shortName: "MM", color: "#e73562", logo: "minimax.svg"),
    "mistral": ProviderBrand(key: "mistral", name: "Mistral AI", shortName: "MI", color: "#e54b13", logo: "mistral.svg"),
    "nousresearch": ProviderBrand(key: "nousresearch", name: "Nous Research", shortName: "NR", color: "#5a5a5a", logo: "nousresearch.png"),
    "nvidia": ProviderBrand(key: "nvidia", name: "NVIDIA", shortName: "NV", color: "#5d9300", logo: "nvidia.svg"),
    "ollama": ProviderBrand(key: "ollama", name: "Ollama", shortName: "O", color: "#4c4c4c", logo: "ollama.png"),
    "openai": ProviderBrand(key: "openai", name: "OpenAI", shortName: "OA", color: "#5c6662", logo: "openai.png"),
    "opencode": ProviderBrand(key: "opencode", name: "opencode", shortName: "OC", color: "#666666", logo: "opencode.png", artwork: true),
    "openrouter": ProviderBrand(key: "openrouter", name: "OpenRouter", shortName: "OR", color: "#6467f2", logo: "openrouter.png", artwork: true),
    "poolside": ProviderBrand(key: "poolside", name: "Poolside", shortName: "PS", color: "#4137ff", logo: "poolside.svg", artwork: true),
    "qwen": ProviderBrand(key: "qwen", name: "Qwen", shortName: "Q", color: "#6950ef", logo: "qwen.svg"),
    "siliconflow": ProviderBrand(key: "siliconflow", name: "SiliconFlow", shortName: "SF", color: "#6736f1", logo: "siliconflow.png", artwork: true),
    "stepfun": ProviderBrand(key: "stepfun", name: "StepFun", shortName: "ST", color: "#5167f4", logo: "stepfun.svg"),
    "nanogpt": ProviderBrand(key: "nanogpt", name: "NanoGPT", shortName: "NG", color: "#0db7b1", logo: "nanogpt.svg", artwork: true),
    "tencent": ProviderBrand(key: "tencent", name: "Tencent", shortName: "T", color: "#0052d9", logo: "tencent.svg", artwork: true),
    "together": ProviderBrand(key: "together", name: "Together AI", shortName: "TA", color: "#d84a15", logo: "together.png", artwork: true),
    "venice": ProviderBrand(key: "venice", name: "Venice", shortName: "VE", color: "#0e2942", logo: "venice.png"),
    "xai": ProviderBrand(key: "xai", name: "xAI", shortName: "X", color: "#606060", logo: "xai.png"),
    "xiaomi": ProviderBrand(key: "xiaomi", name: "Xiaomi", shortName: "MI", color: "#ff6900", logo: "xiaomi.svg"),
    "zai": ProviderBrand(key: "zai", name: "Z.ai", shortName: "Z", color: "#1f63ec", logo: "zai.svg", artwork: true),
  ]

  static let providerBrands: [String: String] = [
    "openai": "openai",
    "anthropic-api": "anthropic",
    "cerebras": "cerebras",
    "chutes": "chutes",
    "clinepass": "cline",
    "commandcode": "commandcode",
    "commandcode-messages": "commandcode",
    // A user-defined endpoint has no brand of its own; it shares the mark of
    // models whose maker is deliberately not disclosed.
    "custom": "stealth",
    "devin-cli": "cognition",
    "deepseek": "deepseek",
    "fireworks": "fireworks",
    "antigravity-oauth": "antigravity",
    "gemini-api": "gemini",
    "github-copilot": "github",
    "grok-api": "xai",
    "grok-oauth": "xai",
    "groq": "groq",
    "huggingface": "huggingface",
    "kimi-api": "kimi",
    "kimi-api-cn": "kimi",
    "kimi-oauth": "kimi",
    "kilo-free": "kilo",
    "lmstudio": "lmstudio",
    "local": "ollama",
    "meta": "meta",
    "minimax-token-plan": "minimax",
    "mistral": "mistral",
    "nano-gpt": "nanogpt",
    "nousresearch": "nousresearch",
    "nvidia-nim": "nvidia",
    "ollama-cloud": "ollama",
    "opencode-go": "opencode",
    "opencode-go-messages": "opencode",
    "opencode-go-responses": "opencode",
    "opencode-zen": "opencode",
    "opencode-free": "opencode",
    "openrouter": "openrouter",
    "qwen-plan": "qwen",
    "siliconflow": "siliconflow",
    "stepfun-api": "stepfun",
    "stepfun-api-cn": "stepfun",
    "together": "together",
    "venice": "venice",
    "vertex": "google",
    "xiaomi-mimo": "xiaomi",
    "zai-api": "zai",
    "zai-coding": "zai",
  ]

  static let fallbackColors = ["#5776a9", "#8b5f8f", "#477c72", "#a46648", "#6e6aa4", "#7d6b49"]

  static func forProvider(_ providerId: String, displayName: String? = nil) -> ProviderBrand {
    let normalized = providerId.trimmingCharacters(in: .whitespaces).lowercased()
    let key = providerBrands[normalized]
      ?? (normalized.hasPrefix("commandcode") ? "commandcode" : nil)
      ?? (normalized.hasPrefix("opencode") ? "opencode" : nil)
      ?? (normalized.hasPrefix("grok") ? "xai" : nil)
      ?? (normalized.hasPrefix("kimi") ? "kimi" : nil)
    if let key, let brand = brands[key] { return brand }
    let name = displayName?.isEmpty == false ? displayName! : humanize(providerId)
    return fallback(name: name, seed: providerId)
  }

  private static func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  static func forModel(provider: String, slug: String, displayName: String? = nil, gatewayModel: String? = nil) -> ProviderBrand {
    let identity = "\(slug) \(displayName ?? "") \(gatewayModel ?? "")".lowercased()
    let ordered: [(String, String)] = [
      ("\\bclaude\\b", "anthropic"),
      ("\\bdeepseek\\b", "deepseek"),
      ("\\bgrok\\b", "xai"),
      ("\\b(?:kimi|moonshot)\\b", "kimi"),
      ("\\bglm(?:-|\\b)", "zai"),
      ("\\bqwen(?:-|\\d|\\b)", "qwen"),
      ("\\bminimax\\b", "minimax"),
      ("\\bgemini\\b", "gemini"),
      ("\\bgemma\\b", "google"),
    ]
    for (pattern, key) in ordered where matches(pattern, identity) {
      if let brand = brands[key] { return brand }
    }
    if matches("\\b(?:gpt|codex)\\b", identity) || slug.lowercased().hasPrefix("openai/") { return brands["openai"]! }
    let later: [(String, String)] = [
      ("\\bmimo(?:-|\\b)", "xiaomi"),
      ("\\bstep(?:-|\\s)", "stepfun"),
      ("\\bhy(?:3|4)(?:-|\\b)", "tencent"),
      ("\\blaguna(?:-|\\b)", "poolside"),
      ("\\b(?:llama|muse spark)\\b", "meta"),
      ("\\b(?:mistral|mixtral|codestral)\\b", "mistral"),
      ("\\bnemotron\\b", "nvidia"),
      ("\\bornith(?:-|\\b)", "deepreinforce"),
    ]
    for (pattern, key) in later where matches(pattern, identity) {
      if let brand = brands[key] { return brand }
    }
    if matches("\\b(?:ox alpha|ox-alpha|omen alpha|omen-alpha|fugu|inkling)\\b", identity) || identity.contains("x-preview") {
      return brands["stealth"]!
    }
    return forProvider(provider)
  }

  static func forLocalModel(tag: String, family: String? = nil, displayName: String? = nil) -> ProviderBrand {
    forModel(
      provider: "local",
      slug: "local/\(tag)",
      displayName: "\(family ?? "") \(displayName ?? "")".trimmingCharacters(in: .whitespaces),
      gatewayModel: tag
    )
  }

  static func humanize(_ providerId: String) -> String {
    providerId
      .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  static func fallback(name: String, seed: String) -> ProviderBrand {
    let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Model provider" : name.trimmingCharacters(in: .whitespaces)
    var hash: Int32 = 0
    for unit in seed.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
    let index = Int(hash.magnitude % UInt32(fallbackColors.count))
    let initials = clean.split(whereSeparator: \.isWhitespace).prefix(2)
      .compactMap { $0.first.map { String($0).uppercased() } }
      .joined()
    let key = "fallback-" + seed.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    return ProviderBrand(key: key, name: clean, shortName: initials.isEmpty ? "MR" : initials, color: fallbackColors[index])
  }

  // MARK: Artwork

  private static var cache: [String: NSImage] = [:]

  /// The packaged app's `Brand/providers`, or the checkout's renderer assets
  /// for a development build.
  static let directory: URL? = {
    if let packaged = Bundle.main.resourceURL?.appendingPathComponent("Brand/providers", isDirectory: true),
      FileManager.default.fileExists(atPath: packaged.path)
    {
      return packaged
    }
    if let bridge = RouterLocator.checkoutBridge(
      environment: ProcessInfo.processInfo.environment,
      executable: URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
    ) {
      // .../apps/control-center/electron/native-bridge.mjs -> .../apps/control-center/src/assets/providers
      return bridge.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("src/assets/providers", isDirectory: true)
    }
    return nil
  }()

  @MainActor
  static func image(_ file: String) -> NSImage? {
    if let cached = cache[file] { return cached }
    guard let directory, let image = NSImage(contentsOf: directory.appendingPathComponent(file)) else { return nil }
    cache[file] = image
    return image
  }
}

/// A provider or model mark: artwork, a tinted mask, or a monogram.
struct BrandLogo: View {
  let brand: ProviderBrand
  var size: CGFloat = 22

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .fill(Palette.hex(brand.color).opacity(brand.artwork ? 0.0 : 0.12))
      if let file = brand.logo, let image = ProviderBranding.image(file) {
        if brand.artwork {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
          Image(nsImage: image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(Palette.hex(brand.color))
            .padding(size * 0.18)
        }
      } else {
        Text(brand.shortName)
          .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
          .foregroundStyle(Palette.hex(brand.color))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct ProviderLogo: View {
  let providerId: String
  var displayName: String?
  var size: CGFloat = 22

  var body: some View {
    BrandLogo(brand: ProviderBranding.forProvider(providerId, displayName: displayName), size: size)
  }
}
