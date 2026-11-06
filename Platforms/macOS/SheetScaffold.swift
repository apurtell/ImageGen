import SwiftUI

/// Sheet layout wrapper providing a header bar with title, optional contextual actions, and a dismissal button.
///
/// Uses an explicit header rather than `NavigationStack` to align title presentation across macOS sheets.
struct SheetScaffold<Content: View, Action: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @ViewBuilder let action: Action
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        Spacer()
        action
        Button("Done") { dismiss() }.defaultActionShortcut()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      Divider()
      content
    }
  }
}

extension SheetScaffold where Action == EmptyView {
  init(title: String, @ViewBuilder content: () -> Content) {
    self.init(title: title, content: content, action: { EmptyView() })
  }
}
