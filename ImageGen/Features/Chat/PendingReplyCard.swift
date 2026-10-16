import SwiftUI

/// A reply in progress (D§3.4): a shimmering card shaped like the requested ratio, the elapsed
/// time, the state's label, and Cancel.
struct PendingReplyCard: View {
  let request: GenerationRequest
  let isNetworkUnavailable: Bool
  let onCancel: () -> Void

  private var aspect: CGFloat {
    CGFloat(request.aspectRatio.flatMap(AspectRatio.init(rawValue:))?.ratio ?? 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TimelineView(.periodic(from: .now, by: 0.5)) { context in
        ZStack {
          RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
          RoundedRectangle(cornerRadius: 12)
            .fill(
              LinearGradient(
                colors: [.clear, .white.opacity(0.25), .clear],
                startPoint: UnitPoint(x: shimmerPhase(context.date) - 0.3, y: 0),
                endPoint: UnitPoint(x: shimmerPhase(context.date) + 0.3, y: 1)))
          VStack(spacing: 6) {
            Text("Generating… \(elapsed(at: context.date))")
              .font(.callout.monospacedDigit())
            if let label = label(at: context.date) {
              Text(label).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxHeight: 360)
        .animation(.linear(duration: 0.5), value: context.date)
      }
      Button("Cancel", systemImage: "xmark.circle", role: .cancel, action: onCancel)
        .font(.callout)
    }
  }

  private func shimmerPhase(_ date: Date) -> CGFloat {
    CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2) * 1.6 - 0.3
  }

  private func elapsed(at date: Date) -> String {
    let start = request.startedAt ?? request.createdAt
    let s = max(0, Int(date.timeIntervalSince(start)))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  private func label(at date: Date) -> String? {
    let input = ReplyPresentation.Input(
      state: request.requestState, modelID: request.modelID, autoRetriesUsed: request.autoRetriesUsed,
      maxAutoRetries: request.maxAutoRetries, nextAttemptAt: request.nextAttemptAt,
      nextAttemptCreatedInBackground: request.nextAttemptCreatedInBackground, isNetworkUnavailable: isNetworkUnavailable,
      now: date)
    if case .pending(let label) = ReplyPresentation.make(input) { return label }
    return nil
  }
}
