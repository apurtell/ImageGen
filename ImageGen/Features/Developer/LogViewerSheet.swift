import SwiftUI
import UIKit

/// Last Action, Last Error or Full Log (D§3.10).
struct LogViewerSheet: View {
  @State var model: LogViewerModel
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    NavigationStack {
      Group {
        if model.isLoaded {
          LogTextView(text: model.text, scrollToBottomOnOpen: model.kind == .fullLog)
        } else {
          ProgressView()
        }
      }
      .safeAreaInset(edge: .top) {
        if model.isInProgress {
          Label("In progress", systemImage: "hourglass")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 4)
        }
      }
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarLeading) {
          Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = model.text
            copied = true
          }
          .accessibilityLabel("Copy")
          ShareLink(item: model.shareFile, preview: SharePreview(model.shareFile.fileName)) {
            Image(systemName: "square.and.arrow.up")
          }
          .accessibilityLabel("Share")
        }
      }
      .overlay(alignment: .bottom) {
        if copied {
          Text("Copied")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassEffect()
            .padding(.bottom, 24)
            .task {
              try? await Task.sleep(for: .seconds(1.5))
              copied = false
            }
        }
      }
    }
    .task { await model.open() }
    .onDisappear { model.close() }
  }
}
