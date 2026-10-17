import Foundation

/// Dimensional and storage footprint descriptor evaluated during request payload budget planning.
struct PreparedSize: Sendable, Equatable {
  let byteCount: Int
  let longEdge: Int
}

/// Discretized decision step emitted by the payload constraint solver.
enum BudgetPlan: Sendable, Equatable {
  case fits(bodyBytes: Int)
  /// Directs targeted downsampling of an input asset to the designated long-edge dimension.
  case shrink(index: Int, toLongEdge: Int, bodyBytes: Int)
  case cannotFit(bodyBytes: Int)
}

/// Error indicating that input images exceed allowable payload budgets even after maximal downsampling.
struct BudgetTooLarge: LocalizedError, Equatable {
  let bodyBytes: Int
  var errorDescription: String? {
    "Images too large to send together (\(String(format: "%.1f", Double(bodyBytes) / 1_000_000)) MB). Remove some or lower the max size in Settings."
  }
}

/// Enforces inline request payload size boundaries by iteratively downsampling input images.
///
/// Strategy:
/// - Evaluates estimated base64 wire payload size against a strict budget ceiling (default 19 MB).
/// - Iteratively selects the largest byte contributor exceeding minimum resolution boundaries
///   and scales its long edge by a decaying factor until the aggregated body satisfies limits.
/// - Guarantees termination as dimensions monotonically decrease toward `minLongEdge`.
enum BudgetPlanner {
  /// Payload budget ceiling reserving headroom under the upstream 20 MB inline transfer limit.
  static let budget = 19_000_000
  static let minLongEdge = 1024
  static let factor = 0.75

  /// Computes predicted request body size accounting for JSON envelope overhead and base64 expansion.
  static func bodySize(_ inputs: [PreparedSize], envelopeBytes: Int) -> Int {
    envelopeBytes + inputs.reduce(0) { $0 + RequestBodyWriter.base64Length($1.byteCount) }
  }

  /// Evaluates current input configurations and determines the next optimization step.
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

  /// Iteratively optimizes and downsamples image inputs until aggregate payload fits within the designated budget.
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
        current[index] = try await shrink(current[index], edge)
        shrinks.append(Shrink(index: index, fromLongEdge: from, toLongEdge: edge))
      }
    }
  }

  /// Default production image downsampling implementation delegating to `ImagePreprocessor`.
  static let shrinkWithPreprocessor: @Sendable (PreparedImage, Int) async throws -> PreparedImage = { image, edge in
    let long = max(image.pixelWidth, image.pixelHeight)
    return try await ImagePreprocessor.shrink(image, factor: Double(edge) / Double(max(1, long)))
  }
}
