import Foundation

/// One input's size, for planning. `byteCount` is the file size before base64 encoding.
struct PreparedSize: Sendable, Equatable {
  let byteCount: Int
  let longEdge: Int
}

/// The next step of the budget loop. An enum with associated values: each case carries its own data.
enum BudgetPlan: Sendable, Equatable {
  case fits(bodyBytes: Int)
  /// Shrink input `index` to `toLongEdge`, then plan again.
  case shrink(index: Int, toLongEdge: Int, bodyBytes: Int)
  case cannotFit(bodyBytes: Int)
}

/// The body cannot fit even with every input at the minimum edge. `RequestPreparer` turns it into a
/// failed send before any network call.
struct BudgetTooLarge: LocalizedError, Equatable {
  let bodyBytes: Int
  var errorDescription: String? {
    "Images too large to send together (\(String(format: "%.1f", Double(bodyBytes) / 1_000_000)) MB). Remove some or lower the max size in Settings."
  }
}

/// Fits a request body under the inline limit by shrinking the largest input first (D§4.8 step 5).
///
/// `RequestPreparer` calls `fit` at send time. `plan` is pure and decides one step; `fit` repeats it and
/// calls the shrink closure, which does the slow work in `ImagePreprocessor`. It holds no state.
enum BudgetPlanner {
  /// The 20 MB inline limit, minus a margin.
  static let budget = 19_000_000
  static let minLongEdge = 1024
  static let factor = 0.75

  /// The predicted body size: the JSON envelope plus each image's base64 length.
  static func bodySize(_ inputs: [PreparedSize], envelopeBytes: Int) -> Int {
    envelopeBytes + inputs.reduce(0) { $0 + RequestBodyWriter.base64Length($1.byteCount) }
  }

  /// Pure: the next step. The largest input (by bytes) that is still above `minLongEdge` shrinks
  /// to 0.75× its long edge, never below `minLongEdge`.
  static func plan(
    inputs: [PreparedSize], envelopeBytes: Int, budget: Int = budget, minLongEdge: Int = minLongEdge
  ) -> BudgetPlan {
    let size = bodySize(inputs, envelopeBytes: envelopeBytes)
    if size <= budget { return .fits(bodyBytes: size) }
    let candidates = inputs.indices.filter { inputs[$0].longEdge > minLongEdge }
    guard let largest = candidates.max(by: { inputs[$0].byteCount < inputs[$1].byteCount }) else {
      return .cannotFit(bodyBytes: size)
    }
    let target = max(minLongEdge, Int((Double(inputs[largest].longEdge) * factor).rounded(.down)))
    return .shrink(index: largest, toLongEdge: target, bodyBytes: size)
  }

  struct Shrink: Sendable, Equatable {
    let index: Int
    let fromLongEdge: Int
    let toLongEdge: Int
  }

  struct Fitted: Sendable, Equatable {
    let images: [PreparedImage]
    let shrinks: [Shrink]
    let bodyBytes: Int
  }

  /// Shrinks until the body fits, checking cancellation between iterations; throws
  /// `BudgetTooLarge` when it can't fit. Cancellation is cooperative: `checkCancellation()` throws if
  /// the send was stopped, so a Stop does not wait for every shrink (see the primer, *Tasks and
  /// cancellation*). The loop ends: each shrink lowers one edge, and no edge goes below `minLongEdge`.
  static func fit(
    _ images: [PreparedImage], envelopeBytes: Int, budget: Int = budget, minLongEdge: Int = minLongEdge,
    shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
  ) async throws -> Fitted {
    var current = images
    var shrinks: [Shrink] = []
    while true {
      try Task.checkCancellation()
      let sizes = current.map { PreparedSize(byteCount: $0.byteCount, longEdge: max($0.pixelWidth, $0.pixelHeight)) }
      switch plan(inputs: sizes, envelopeBytes: envelopeBytes, budget: budget, minLongEdge: minLongEdge) {
      case .fits(let bytes):
        return Fitted(images: current, shrinks: shrinks, bodyBytes: bytes)
      case .cannotFit(let bytes):
        throw BudgetTooLarge(bodyBytes: bytes)
      case .shrink(let index, let edge, _):
        let from = sizes[index].longEdge
        // A suspension point: the shrink runs in the background, and this task waits for it.
        current[index] = try await shrink(current[index], edge)
        shrinks.append(Shrink(index: index, fromLongEdge: from, toLongEdge: edge))
      }
    }
  }

  /// The production shrink: a factor from the current edge to the target. Tests supply a fake.
  static let shrinkWithPreprocessor: @Sendable (PreparedImage, Int) async throws -> PreparedImage = { image, edge in
    let long = max(image.pixelWidth, image.pixelHeight)
    return try await ImagePreprocessor.shrink(image, factor: Double(edge) / Double(max(1, long)))
  }
}
