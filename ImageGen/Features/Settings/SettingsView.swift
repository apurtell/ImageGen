import SwiftUI

/// Root Settings modal sheet aggregating configuration sections for credentials, model catalog,
/// generation defaults, upload limits, advanced transport options, notifications, storage, and
/// application info.
struct SettingsView: View {
  @State var keyModel: APIKeySectionModel
  @State var model: SettingsModel
  @Environment(\.dismiss) private var dismiss
  @Environment(Navigator.self) private var navigator

  var body: some View {
    @Bindable var navigator = navigator
    // Bind navigation stack path to navigator state to support deep-linking directly into sub-pages.
    NavigationStack(path: $navigator.settingsPath) {
      Form {
        // Transition to onboarding workflow if credentials are deleted.
        APIKeySection(model: keyModel) {
          dismiss()
          navigator.needsOnboarding = true
        }
        Section {
          NavigationLink(value: SettingsPage.models) {
            LabeledContent("Models", value: "\(model.settings.enabledModelIDs.count + model.settings.customModelIDs.count) enabled")
          }
        } header: {
          Text("Models")
        } footer: {
          Text("New chats always use Gemini 3.1 Flash Image. Chats can switch models from the composer.")
        }
        GenerationDefaultsSection(model: model)
        UploadsSection(model: model)
        AdvancedSection(model: model)
        NotificationsSection(model: model)
        StorageSection(model: model)
        AboutSection(model: model)
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .navigationDestination(for: SettingsPage.self) { page in
        switch page {
        case .models: ModelsSettingsView(model: model)
        }
      }
    }
    .toast(model.toast, offset: 64)
    // Synchronize storage metrics and notification permissions upon sheet presentation.
    .task {
      await model.refreshSizes()
      await model.refreshNotificationStatus()
    }
  }
}

/// Renders API credential status, on-demand validation triggers, replacement forms, and revocation actions.
struct APIKeySection: View {
  let model: APIKeySectionModel
  let onRemoved: () -> Void
  @State private var confirmRemove = false

  var body: some View {
    Section("API Key") {
      LabeledContent("Status", value: model.statusText)
      if let replace = model.replace {
        ReplaceKeyForm(model: replace, onSaved: { model.replaceFinished() }, onCancel: { model.cancelReplace() })
      } else {
        Button("Replace Key") { model.beginReplace() }
        if model.hasKey {
          // Disable validation trigger while asynchronous check is active.
          Button {
            Task { await model.validateNow() }
          } label: {
            HStack {
              Text("Validate Now")
              Spacer()
              if model.validation == .validating { ProgressView() }
            }
          }
          .disabled(model.validation == .validating)
          switch model.validation {
          case .valid(let text): Label(text, systemImage: "checkmark.seal").foregroundStyle(.green)
          case .problem(let text): Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          default: EmptyView()
          }
          Button("Remove Key", role: .destructive) { confirmRemove = true }
        }
      }
    }
    .confirmationDialog("Remove the API key?", isPresented: $confirmRemove, titleVisibility: .visible) {
      Button("Remove Key", role: .destructive) {
        if model.removeKey() { onRemoved() }
      }
    } message: {
      Text("You'll need to enter a key again to generate images.")
    }
  }
}

/// Inline form component for entering, verifying, and persisting a replacement API credential.
private struct ReplaceKeyForm: View {
  @Bindable var model: OnboardingModel
  let onSaved: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack {
      Group {
        if model.reveal {
          TextField("New API key", text: $model.keyText)
        } else {
          SecureField("New API key", text: $model.keyText)
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
      .buttonStyle(.borderless)
      .accessibilityLabel(model.reveal ? "Hide key" : "Show key")
    }
    switch model.phase {
    case .rejected(let message):
      Label("Key rejected: \(message)", systemImage: "key").foregroundStyle(.red)
    case .unreachable(let message):
      Label("Couldn't reach Google (\(message))", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
      Button("Save Anyway") { if model.saveAnyway() { onSaved() } }
    default:
      EmptyView()
    }
    HStack {
      Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.borderless)
      Spacer()
      Button {
        Task { if await model.validateAndSave() { onSaved() } }
      } label: {
        HStack {
          if model.phase == .validating { ProgressView() }
          Text("Validate and Save")
        }
      }
      .buttonStyle(.borderless)
      .disabled(!model.canValidate)
    }
  }
}

/// Configuration controls for global generation defaults, including aspect ratio, resolution, and safety thresholds.
struct GenerationDefaultsSection: View {
  let model: SettingsModel

  var body: some View {
    let s = model.settings
    Section {
      Picker(
        "Aspect ratio",
        selection: Binding(get: { s.defaultAspectRatio }, set: { model.setDefaultAspect($0) })
      ) {
        ForEach(Self.aspectOrder, id: \.self) { Text($0.rawValue).tag($0) }
      }
      Picker("Resolution", selection: Binding(get: { s.defaultImageSize }, set: { model.setDefaultSize($0) })) {
        ForEach(ImageSize.allCases, id: \.self) { Text(Self.sizeLabel($0)).tag($0) }
      }
      Picker("Safety", selection: Binding(get: { s.safetyThreshold }, set: { model.setThreshold($0) })) {
        ForEach(SafetyThreshold.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
    } header: {
      Text("Generation defaults")
    } footer: {
      Text("Chats can override these from the composer. Unsupported combinations are adjusted per model.")
    }
  }

  /// Ordered aspect ratio choices categorized across landscape, square, portrait, and panoramic groupings.
  static let aspectOrder: [AspectRatio] = [
    .r16x9, .r21x9, .r3x2, .r4x3, .r5x4, .r1x1, .r9x16, .r2x3, .r3x4, .r4x5, .r4x1, .r8x1, .r1x4, .r1x8,
  ]

  static func sizeLabel(_ s: ImageSize) -> String {
    switch s {
    case .s512: "512 px"
    case .s1K: "1K (~1 MP)"
    case .s2K: "2K (~4 MP)"
    case .s4K: "4K (~16 MP)"
    }
  }
}

/// Configuration section governing maximum dimensions for uploaded image preprocessing.
struct UploadsSection: View {
  let model: SettingsModel

  var body: some View {
    Section {
      Picker(
        "Max long edge",
        selection: Binding(get: { model.settings.maxUploadLongEdge }, set: { model.setMaxLongEdge($0) })
      ) {
        ForEach(AppSettings.allowedLongEdges, id: \.self) { Text(verbatim: "\($0) px").tag($0) }
      }
    } header: {
      Text("Uploads")
    } footer: {
      Text("Uploaded photos are resized and converted to JPEG before sending. Originals are kept in the chat.")
    }
  }
}

/// Advanced options configuring request payload formatting and safety filtering exceptions.
struct AdvancedSection: View {
  let model: SettingsModel

  var body: some View {
    Section("Advanced") {
      Toggle(
        "Request text alongside images",
        isOn: Binding(get: { model.settings.includeTextModality }, set: { model.setIncludeText($0) }))
      Toggle(
        "Omit deprecated CIVIC_INTEGRITY category",
        isOn: Binding(get: { model.settings.omitCivicIntegrity }, set: { model.setOmitCivic($0) }))
    }
  }
}

/// Manages notification delivery authorization and background generation completion alerts.
struct NotificationsSection: View {
  let model: SettingsModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    Section("Notifications") {
      LabeledContent("Status", value: model.notificationStatusText)
      // Guide user to iOS Settings if notifications were previously disabled.
      if model.notificationStatus == "denied" {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
      }
      Toggle(
        "Notify when a generation finishes in the background",
        isOn: Binding(get: { model.settings.notifyOnBackgroundCompletion }, set: { model.setNotify($0) }))
    }
  }
}

/// Storage consumption metrics, thumbnail cache reclamation, and destructive conversation purging controls.
struct StorageSection: View {
  let model: SettingsModel
  /// State flags coordinating multi-stage confirmation dialogs for destructive chat deletion.
  @State private var confirmDelete = false
  @State private var confirmDeleteAgain = false

  private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

  var body: some View {
    Section("Storage") {
      LabeledContent("Images", value: size(model.sizes.images))
      LabeledContent("Requests", value: size(model.sizes.requests + model.sizes.staging))
      LabeledContent("Thumbnail cache", value: size(model.sizes.thumbnails))
      LabeledContent("Total", value: size(model.totalBytes)).bold()
      Button("Clear Thumbnail Cache") { Task { await model.clearThumbnailCache() } }
      Button("Delete All Chats", role: .destructive) { confirmDelete = true }
        .confirmationDialog("Delete all chats?", isPresented: $confirmDelete, titleVisibility: .visible) {
          Button("Delete All Chats", role: .destructive) { confirmDeleteAgain = true }
        } message: {
          Text("Every chat and its images will be removed from this iPhone.")
        }
        .alert("Are you sure?", isPresented: $confirmDeleteAgain) {
          Button("Delete Everything", role: .destructive) { Task { await model.deleteAllChats() } }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("This can't be undone. Images you saved to Photos or Files are kept.")
        }
    }
  }
}

/// Information section displaying application version metadata, active model identifiers, and watermarking disclosures.
struct AboutSection: View {
  let model: SettingsModel

  private var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
  }

  var body: some View {
    Section {
      LabeledContent("Version", value: version)
      LabeledContent("Default model", value: ModelCatalog.defaultModelID)
      let others = model.settings.enabledModelIDs.subtracting([ModelCatalog.defaultModelID]).sorted() + model.settings.customModelIDs
      if !others.isEmpty {
        LabeledContent("Also enabled") {
          Text(others.joined(separator: "\n")).multilineTextAlignment(.trailing).font(.footnote.monospaced())
        }
      }
    } header: {
      Text("About")
    } footer: {
      Text("Images made by Gemini carry Google's invisible SynthID watermark.")
    }
  }
}
