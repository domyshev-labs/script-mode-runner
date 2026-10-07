import SwiftUI

// Keep natural widths until the row fills, then shrink long tabs first.
struct ProcessTabsLayout: Layout {
    let availableWidth: CGFloat
    var spacing: CGFloat = 8

    private func widths(for subviews: Subviews) -> [CGFloat] {
        processTabWidths(idealWidths: subviews.map { $0.sizeThatFits(.unspecified).width },
                         availableWidth: availableWidth, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: subviews)
        let height = zip(subviews, widths).map {
            $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, widths(for: subviews)) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

func processTabWidths(idealWidths: [CGFloat], availableWidth: CGFloat,
                      spacing: CGFloat = 8, minimumWidth: CGFloat = 96) -> [CGFloat] {
    guard !idealWidths.isEmpty else { return [] }
    let budget = max(0, availableWidth - CGFloat(idealWidths.count - 1) * spacing)
    guard idealWidths.reduce(0, +) > budget else { return idealWidths }
    let minimums = idealWidths.map { min($0, minimumWidth) }
    // When even the minimum widths do not fit, preserve usable tabs and scroll.
    guard minimums.reduce(0, +) < budget else { return minimums }
    var low: CGFloat = 0
    var high = idealWidths.max() ?? 0
    for _ in 0..<40 {
        let cap = (low + high) / 2
        let total = zip(idealWidths, minimums).reduce(CGFloat.zero) {
            $0 + max($1.1, min($1.0, cap))
        }
        if total > budget { high = cap } else { low = cap }
    }
    return zip(idealWidths, minimums).map { max($1, min($0, low)) }
}
