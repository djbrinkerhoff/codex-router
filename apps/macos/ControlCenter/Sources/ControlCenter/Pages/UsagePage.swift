import ControlCenterCore
import SwiftUI

/// Placeholder until the Usage page port lands.
struct UsagePage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("usage.eyebrow"),
      title: model.label(for: .usage),
      description: model.description(for: .usage)
    )
  }
}
