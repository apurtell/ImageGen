import SwiftUI

/// A reply in progress (D§3.4): a shimmering card shaped like the requested ratio, the elapsed
/// time, the state's label, and Cancel.
///
/// The card has no timer task of its own: `TimelineView(.periodic)` asks SwiftUI to redraw its
/// content every 0.5 s with the current date, and the elapsed time, the shimmer and the retry
/// countdown are all computed from that date. When the request's state changes, `ModelReplyView`
/// stops showing this card, and the redraws stop with it.
struct PendingReplyCard: View {
  let request: GenerationRequest
  let isNetworkUnavailable: Bool
  let onCancel: () -> Void

  /// The requested ratio; "Auto" (no ratio) draws a square.
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

  /// A 2-second cycle from -0.3 to 1.3, so the bright band enters and leaves the card fully.
  private func shimmerPhase(_ date: Date) -> CGFloat {
    CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2) * 1.6 - 0.3
  }

  /// "m:ss" since `startedAt` (D§3.4), or since the record was made while it is still preparing.
  private func elapsed(at date: Date) -> String {
    let start = request.startedAt ?? request.createdAt
    let s = max(0, Int(date.timeIntervalSince(start)))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// The line under the timer, from the same rules as the rest of the reply (`ReplyPresentation`).
  /// It is computed again at each tick, so the "Retrying in N s" countdown moves.
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
