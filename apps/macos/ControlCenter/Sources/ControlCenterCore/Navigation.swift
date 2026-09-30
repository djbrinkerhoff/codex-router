import Foundation

/// A request from the tray to open a specific Control Center page, ported
/// from `apps/control-center/electron/navigation.mjs`. It arrives either as
/// launch arguments (cold start) or as a `codex-router://control-center/...`
/// URL Apple Event (warm start); both carry the same validated request.
public struct NavigationRequest: Equatable, Sendable {
  public enum Destination: String, Sendable, CaseIterable {
    case usage
    case usageResets = "usage-resets"
  }

  public static let destinationArgument = "--router-destination"
  public static let sourceArgument = "--router-source"

  public let destination: Destination
  public let sourceID: String?

  public init(destination: Destination, sourceID: String? = nil) {
    self.destination = destination
    self.sourceID = sourceID
  }

  static func validSourceID(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...64).contains(scalars.count) else { return false }
    func lowerAlnum(_ scalar: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
    guard lowerAlnum(scalars[0]) else { return false }
    return scalars.dropFirst().allSatisfy { lowerAlnum($0) || $0 == "-" }
  }

  /// Exactly one known destination and at most one valid source, or nothing.
  public init?(arguments: [String]) {
    var destinations: [String?] = []
    var sources: [String?] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == Self.destinationArgument {
        destinations.append(index + 1 < arguments.count ? arguments[index + 1] : nil)
        index += 2
      } else if arguments[index] == Self.sourceArgument {
        sources.append(index + 1 < arguments.count ? arguments[index + 1] : nil)
        index += 2
      } else {
        index += 1
      }
    }
    guard destinations.count == 1, let raw = destinations[0], let destination = Destination(rawValue: raw) else { return nil }
    guard sources.count <= 1 else { return nil }
    if sources.count == 1 {
      guard let source = sources[0], Self.validSourceID(source) else { return nil }
      self.init(destination: destination, sourceID: source)
    } else {
      self.init(destination: destination, sourceID: nil)
    }
  }

  public init?(url: URL) {
    guard url.scheme == "codex-router",
      url.host == "control-center",
      url.user == nil,
      url.password == nil,
      url.port == nil,
      url.fragment == nil,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let destination: Destination
    switch components.path {
    case "/usage": destination = .usage
    case "/usage-resets": destination = .usageResets
    default: return nil
    }
    let items = components.queryItems ?? []
    guard items.allSatisfy({ $0.name == "source" }), items.count <= 1 else { return nil }
    if let item = items.first {
      guard let source = item.value, Self.validSourceID(source) else { return nil }
      self.init(destination: destination, sourceID: source)
    } else {
      self.init(destination: destination, sourceID: nil)
    }
  }
}
