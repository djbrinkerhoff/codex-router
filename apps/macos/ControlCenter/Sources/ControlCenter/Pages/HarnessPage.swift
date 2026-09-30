import ControlCenterCore
import SwiftUI

/// Placeholder until the Harness page port lands.
struct HarnessPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("harness.eyebrow"),
      title: model.label(for: .harness),
      description: model.description(for: .harness)
    )
  }
}
