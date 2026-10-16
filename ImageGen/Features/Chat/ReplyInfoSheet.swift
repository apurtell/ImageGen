import SwiftData
import SwiftUI

/// A reply's Info (D§3.6): the recorded settings, how the input was chosen, timing and the
/// response identifiers; for a refusal the `finishMessage`; the redacted JSON under Details.
struct ReplyInfoSheet: View {
  let request: GenerationRequest
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @State private var showDetails = false

  static func inputDescription(_ reason: SelectionReason) -> String {
    switch reason {
    case .attachments: "Attachments"
    case .pinned: "Edited from pinned image"
    case .latest: "Edited latest image"
    case .noImage: "Text only"
    }
  }

  private var inputAssets: [ImageAsset] {
    request.inputs.compactMap { input in
      let id = input.imageID
      return try? context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })).first
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Request") {
          row("Model", request.modelID)
          row("Aspect", request.aspectRatio ?? "omitted")
          row("Size", request.imageSize ?? "omitted")
          row("Safety", request.safetyThreshold)
          row("Categories", request.categories.map { $0.rawValue.replacingOccurrences(of: "HARM_CATEGORY_", with: "") }.joined(separator: ", "))
          row("Modalities", request.includeTextModality ? "TEXT+IMAGE" : "IMAGE")
          row("Attempt", "\(request.attempt)")
        }
        Section("Input") {
          Text("Input: \(Self.inputDescription(SelectionReason(rawValue: request.selectionReason) ?? .noImage))")
          if !inputAssets.isEmpty {
            ScrollView(.horizontal) {
              HStack { ForEach(inputAssets) { SquareThumbnail(asset: $0, size: 56) } }
            }
          }
        }
        Section("Response") {
          if let reason = request.refusalReason { row("Refused", reason) }
          if request.requestState == .refused, let message = request.errorMessage { Text("Message: \(message)") }
          if let finish = request.finishReason { row("Finish reason", finish) }
          if let version = request.modelVersion { row("Model version", version) }
          if let id = request.responseID { row("Response ID", id) }
          if let status = request.httpStatus { row("HTTP", "\(status)") }
          if let w = request.outputWidth, let h = request.outputHeight { row("Output", "\(w)×\(h)") }
          row("Created", request.createdAt.formatted(date: .abbreviated, time: .standard))
          if let s = request.startedAt { row("Started", s.formatted(date: .omitted, time: .standard)) }
          if let c = request.completedAt { row("Completed", c.formatted(date: .omitted, time: .standard)) }
        }
        if request.details != nil {
          Section { Button("Details") { showDetails = true } }
        }
      }
      .navigationTitle("Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .sheet(isPresented: $showDetails) { DetailsSheet(text: request.details ?? "") }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    LabeledContent(label) { Text(value).textSelection(.enabled) }
  }
}
