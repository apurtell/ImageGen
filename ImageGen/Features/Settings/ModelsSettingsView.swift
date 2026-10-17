import SwiftUI

/// Settings › Models (D§3.8): the fixed default, a toggle per other catalog model with its
/// availability, custom IDs, and pull to refresh.
///
/// A page pushed inside the Settings sheet. It shares the sheet's `SettingsModel`, which logs each
/// change, checks custom IDs with the service, and runs the models refresh. It runs on the main
/// actor; Add, Check Now and pull to refresh each start one `Task` or async call.
struct ModelsSettingsView: View {
  let model: SettingsModel
  /// The Add field's text, and the message under it after a refused Add.
  @State private var newID = ""
  @State private var addError: String?

  var body: some View {
    List {
      Section {
        LabeledContent("Default model", value: "Gemini 3.1 Flash Image")
      } footer: {
        Text("Always used for new chats; it can't be turned off.")
      }

      Section {
        ForEach(model.toggleableModels) { m in
          Toggle(isOn: Binding(get: { model.isEnabled(m.id) }, set: { model.setEnabled(m.id, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
              Text(m.displayName)
              Text(model.availability(m.id).label)
                .font(.caption)
                .foregroundStyle(model.availability(m.id) == .available ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
          }
        }
      } header: {
        Text("Models")
      } footer: {
        Text("Chats set to a model you turn off or remove use Gemini 3.1 Flash Image until it's turned back on.")
      }

      Section {
        ForEach(model.settings.customModelIDs, id: \.self) { id in
          Text(id).font(.body.monospaced())
        }
        // Swipe to delete. The model logs each removal.
        .onDelete { offsets in
          for i in offsets { model.removeCustomModel(model.settings.customModelIDs[i]) }
        }
        HStack {
          TextField("Model ID, e.g. gemini-x-image", text: $newID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            // Return can submit again while a check runs. The model refuses the second call, so
            // there is one check at a time.
            .onSubmit { Task { await add() } }
          // The spinner replaces Add while a check runs, so the button cannot start a second one.
          if model.isAddingModel {
            ProgressView()
          } else {
            Button("Add") { Task { await add() } }
              .disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
        if let addError {
          Text(addError).font(.footnote).foregroundStyle(.red)
        }
      } header: {
        Text("Custom models")
      } footer: {
        Text("Each ID is checked with Google before it's added. Swipe to remove one.")
      }

      Section {
        Button {
          Task { await model.refreshModels() }
        } label: {
          HStack {
            Text("Check Now")
            Spacer()
            if model.isRefreshingModels { ProgressView() }
          }
        }
        .disabled(model.isRefreshingModels)
      } footer: {
        if let checked = model.lastChecked {
          Text("Last checked \(checked, format: .relative(presentation: .named)). Pull down to check again.")
        } else {
          Text("Not checked yet.")
        }
      }
    }
    .navigationTitle("Models")
    .navigationBarTitleDisplayMode(.inline)
    // `.refreshable` adds pull to refresh; the spinner stays until the call returns.
    .refreshable { await model.refreshModels() }
  }

  /// Add, or Return in the field. The field is cleared only after a successful add, so a refused ID
  /// stays for the user to correct.
  private func add() async {
    addError = nil
    switch await model.addCustomModel(newID) {
    case .added: newID = ""
    case .invalid(let why), .rejected(let why): addError = why
    }
  }
}
