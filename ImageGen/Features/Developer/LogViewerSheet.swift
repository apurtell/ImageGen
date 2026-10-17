import SwiftUI
import UIKit

/// Last Action, Last Error or Full Log (D§3.10).
///
/// The sheet that `DeveloperMenu` presents. It shows the model's text in `LogTextView` and offers
/// Done, Copy and Share. Its lifecycle drives the model: `.task` loads and starts following the log,
/// and `.onDisappear` stops following. It runs on the main actor.
struct LogViewerSheet: View {
  /// `@State` keeps the one model for the life of the sheet, also when SwiftUI rebuilds this struct.
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
      // Copy and Share use the current text, so they include lines that arrived while open.
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
          // A `ShareLink` is enough here: sharing the log is not logged, so no completion is needed.
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
            // The toast's own `.task`: it starts when the toast appears and is cancelled if it goes away.
            .task {
              try? await Task.sleep(for: .seconds(1.5))  // try?: a cancelled sleep only hides the toast early.
              copied = false
            }
        }
      }
    }
    .task { await model.open() }
    .onDisappear { model.close() }
  }
}
