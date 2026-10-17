import SwiftUI

/// Flexible wrapping container layout arranging child views horizontally at their intrinsic dimensions,
/// advancing to subsequent rows when container width boundaries are reached.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  /// Measures the container footprint required to accommodate arranged rows within the proposed bounds.
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  /// Positions child subviews along computed row lines, applying vertical centering within each row band.
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  /// Groups subviews into sequential row allocations using a greedy line-wrapping algorithm.
  private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for (i, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if !current.indices.isEmpty && needed > width {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(i)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
