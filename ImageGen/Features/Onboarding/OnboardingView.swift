import SwiftUI

/// First launch onboarding view presenting credential configuration and validation workflows,
/// transitioning to the primary chat interface upon verified persistence.
struct OnboardingView: View {
  @State var model: OnboardingModel
  /// Completion handler invoked upon successful credential configuration and warning acknowledgment.
  let onFinished: () -> Void
  @State private var showFlashWarning = false
  @FocusState private var keyFieldFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Connect Gemini").font(.largeTitle.bold())
          Text("ImageGen talks to Google's Gemini API with your own API key. The key is stored in the Keychain on this \(Platform.deviceNoun) and never shown again.")
            .foregroundStyle(.secondary)
          APIKeySourceLink()
          HStack {
            // Dynamically alternate between obscured SecureField and plaintext TextField based on visibility state.
            Group {
              if model.reveal {
                TextField("API key", text: $model.keyText)
              } else {
                SecureField("API key", text: $model.keyText)
              }
            }
            .framelessFieldStyle()
            .focused($keyFieldFocused)
            .takesInitialFocus($keyFieldFocused)
            .submitsOnReturn { submit() }
            .neverAutocapitalize()
            .autocorrectionDisabled()
            .apiKeyContentType()
            Button {
              model.reveal.toggle()
            } label: {
              Image(systemName: model.reveal ? "eye.slash" : "eye")
            }
            .chromelessButton()
            .tooltip(model.reveal ? "Hide key" : "Show key")
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
              Text("Validate and Save").onboardingButtonLabel()
            }
            .padding(.vertical, 6)
          }
          .buttonStyle(.glassProminent)
          .defaultActionShortcut()
          .disabled(!model.canValidate)
          .onboardingButtonPlacement()
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

  private func submit() {
    guard model.canValidate else { return }
    Task { await validate() }
  }

  /// Dispatches asynchronous credential verification and routes to completion or advisory warnings.
  private func validate() async {
    guard await model.validateAndSave() else { return }
    // Prompt with non-blocking advisory alert if the validated key lacks explicit Flash model entitlements.
    if case .saved(let warn) = model.phase, warn {
      showFlashWarning = true
    } else {
      onFinished()
    }
  }
}
