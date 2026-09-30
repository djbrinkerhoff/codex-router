import ControlCenterCore
import SwiftUI

/// Placeholder until the Context page port lands.
struct ContextPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("context.eyebrow"),
      title: model.label(for: .context),
      description: model.description(for: .context)
    )
  }
}
