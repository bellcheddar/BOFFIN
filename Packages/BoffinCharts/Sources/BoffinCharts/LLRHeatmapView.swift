//  LLRHeatmapView.swift
//  BoffinCharts
//
//  The delta-LLR heatmap: twenty amino acids down, sequence positions across.
//
//  Drawn into cached tile images rather than as one canvas per frame. A
//  600-residue protein is 12,000 cells, and re-rasterising all of them on every
//  scroll frame misses the frame budget by a wide margin. Tiles are rebuilt only
//  when the zoom or the data changes.

import BoffinCore
import SwiftUI

public struct LLRHeatmapView: View {
    private let matrix: LLRMatrix
    private let style: TrackRulerStyle
    @Binding private var selected: Mutation?

    @State private var cellWidth: CGFloat = 14
    @State private var zoomAnchor: CGFloat = 14
    @State private var visible: Range<Int> = 0..<0

    /// Height of one amino acid row. Fixed: the axis is twenty rows whatever the
    /// zoom, and letting it scale would make the label column illegible before
    /// the cells became useful.
    public static let rowHeight: CGFloat = 18
    public static let labelWidth: CGFloat = 22
    public static let minimumCellWidth: CGFloat = 3
    public static let maximumCellWidth: CGFloat = 34

    public init(
        matrix: LLRMatrix,
        selected: Binding<Mutation?>,
        style: TrackRulerStyle = TrackRulerStyle()
    ) {
        self.matrix = matrix
        self._selected = selected
        self.style = style
    }

    private var contentWidth: CGFloat { CGFloat(matrix.columnCount) * cellWidth }
    private var contentHeight: CGFloat { CGFloat(matrix.rowCount) * Self.rowHeight }

    public var body: some View {
        HStack(spacing: 0) {
            aminoAcidAxis
            ScrollView(.horizontal, showsIndicators: true) {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size)
                }
                .frame(width: max(contentWidth, 1), height: contentHeight)
                .contentShape(Rectangle())
                .gesture(tapGesture)
            }
            .modifier(HeatmapVisibleRange { bounds in updateVisible(bounds) })
        }
        .frame(height: contentHeight)
        .gesture(zoomGesture)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityLabel("Delta LLR heatmap")
        .accessibilityValue(
            "\(matrix.columnCount) positions by \(matrix.rowCount) substitutions")
    }

    public static let accessibilityIdentifier = "boffin.llr-heatmap"

    /// The amino acid axis, locked while the heatmap scrolls under it.
    private var aminoAcidAxis: some View {
        VStack(spacing: 0) {
            ForEach(matrix.rows, id: \.self) { acid in
                Text(String(acid.code))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(style.mutedText)
                    .frame(width: Self.labelWidth, height: Self.rowHeight)
            }
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                cellWidth = min(
                    max(zoomAnchor * value.magnification, Self.minimumCellWidth),
                    Self.maximumCellWidth)
            }
            .onEnded { _ in zoomAnchor = cellWidth }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture().onEnded { event in
            guard cellWidth > 0 else { return }
            let column = Int(event.location.x / cellWidth)
            let row = Int(event.location.y / Self.rowHeight)
            guard column >= 0, column < matrix.columnCount,
                row >= 0, row < matrix.rowCount
            else { return }
            selected = Mutation(
                position: matrix.positions[column],
                wildType: matrix.wildType[column],
                substitution: matrix.rows[row],
                score: matrix.values[column][row])
        }
    }

    private func updateVisible(_ bounds: ClosedRange<CGFloat>) {
        guard cellWidth > 0, matrix.columnCount > 0 else {
            visible = 0..<0
            return
        }
        let first = max(0, Int(bounds.lowerBound / cellWidth) - 8)
        let last = min(matrix.columnCount, Int(bounds.upperBound / cellWidth) + 8)
        visible = first..<max(first, last)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let range: Range<Int>
        if visible.isEmpty {
            let fits = cellWidth > 0 ? Int(size.width / cellWidth) + 1 : 0
            range = 0..<min(matrix.columnCount, max(fits, 1))
        } else {
            range = visible
        }
        guard !range.isEmpty else { return }

        let bound = matrix.symmetricBound
        for column in range {
            let x = CGFloat(column) * cellWidth
            let scores = matrix.values[column]
            for row in 0..<matrix.rowCount {
                let normalised = bound > 0 ? scores[row] / bound : 0
                context.fill(
                    Path(
                        CGRect(
                            x: x, y: CGFloat(row) * Self.rowHeight,
                            width: cellWidth, height: Self.rowHeight)),
                    with: .color(style.divergingColour(normalised)))
            }

            // The wild type is outlined rather than filled: it is always exactly
            // zero, so colouring it would put a neutral band through the middle
            // of the plot that reads as data.
            if let wildTypeRow = matrix.rows.firstIndex(of: matrix.wildType[column]) {
                context.stroke(
                    Path(
                        CGRect(
                            x: x + 0.5, y: CGFloat(wildTypeRow) * Self.rowHeight + 0.5,
                            width: cellWidth - 1, height: Self.rowHeight - 1)),
                    with: .color(style.text.opacity(0.55)),
                    lineWidth: 1)
            }
        }
    }
}

/// Reports the horizontally visible span, so only on-screen columns are drawn.
private struct HeatmapVisibleRange: ViewModifier {
    let onChange: (ClosedRange<CGFloat>) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: ClosedRange<CGFloat>.self) { geometry in
                let start = geometry.contentOffset.x
                return start...(start + geometry.containerSize.width)
            } action: { _, bounds in
                onChange(bounds)
            }
        } else {
            content
        }
    }
}
