import SwiftUI

/// Connect Gemini (D§3.2).
///
/// The form that `RootView` shows in place of the chat list while `needsOnboarding` is set (no key
/// in the Keychain). The view draws `OnboardingModel.phase`; the model does the checks, the saving
/// and the logging. `onFinished` clears `needsOnboarding`, and the root then shows the chat list.
/// It runs on the main actor; each button starts one `Task`.
struct OnboardingView: View {
  /// `@State` keeps one model for the life of this screen.
  @State var model: OnboardingModel
  /// Called once the key is saved (after the Flash warning, when there is one).
  let onFinished: () -> Void
  @State private var showFlashWarning = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Connect Gemini").font(.largeTitle.bold())
          Text("ImageGen talks to Google's Gemini API with your own API key. The key is stored in the Keychain on this iPhone and never shown again.")
            .foregroundStyle(.secondary)
          Text("Get a key at aistudio.google.com/apikey")
            .font(.callout.monospaced())
            .textSelection(.enabled)
          HStack {
            // The reveal toggle swaps a secure field for a plain one. Both bind to the same text.
            Group {
              if model.reveal {
                TextField("API key", text: $model.keyText)
              } else {
                SecureField("API key", text: $model.keyText)
              }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            Button {
              model.reveal.toggle()
            } label: {
              Image(systemName: model.reveal ? "eye.slash" : "eye")
            }
            .accessibilityLabel(model.reveal ? "Hide key" : "Show key")
          }
          .padding(12)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

          switch model.phase {
          case .rejected(let message):
            Label("Key rejected: \(message)", systemImage: "key").foregroundStyle(.red)
          case .unreachable(let message):
            VStack(alignment: .leading, spacing: 8) {
              Label("Couldn't reach Google (\(message))", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
              HStack {
                Button("Retry") { Task { await validate() } }.buttonStyle(.bordered)
                Button("Save Anyway") { if model.saveAnyway() { onFinished() } }.buttonStyle(.bordered)
              }
            }
          default:
            EmptyView()
          }

          Button {
            Task { await validate() }
          } label: {
            HStack {
              if model.phase == .validating { ProgressView() }
              Text("Validate & Save").frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
          }
          .buttonStyle(.glassProminent)
          .disabled(!model.canValidate)
        }
        .padding(24)
      }
      .alert("Gemini 3.1 Flash Image not listed", isPresented: $showFlashWarning) {
        Button("OK") { onFinished() }
      } message: {
        Text(OnboardingModel.flashWarning)
      }
    }
  }

  /// Validate & Save, or Retry. The model's `phase` shows the outcome when nothing is saved.
  private func validate() async {
    guard await model.validateAndSave() else { return }
    // The key is saved. A missing Flash model is a warning, not a failure: the alert's OK finishes.
    if case .saved(let warn) = model.phase, warn {
      showFlashWarning = true
    } else {
      onFinished()
    }
  }
}
