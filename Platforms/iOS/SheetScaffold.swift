import SwiftUI

/// Standardized modal sheet scaffold hosting navigation bar chrome, title presentation, and dismissal actions.
struct SheetScaffold<Content: View, Action: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @ViewBuilder let action: Action
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(title)
        .inlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.defaultActionShortcut() }
          if Action.self != EmptyView.self {
            ToolbarItem(placement: .sheetLeadingBar) { action }
          }
        }
    }
  }
}

extension SheetScaffold where Action == EmptyView {
  init(title: String, @ViewBuilder content: () -> Content) {
    self.init(title: title, content: content, action: { EmptyView() })
  }
}
