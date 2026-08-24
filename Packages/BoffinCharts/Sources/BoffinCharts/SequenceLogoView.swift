//  SequenceLogoView.swift
//  BoffinCharts
//
//  The sequence logo: stacked glyphs whose total height is the information
//  content at that position, and whose individual heights are each residue's
//  share of it.
//
//  The mathematics lives in `InformationContent` and is tested against
//  hand-computed values. This file is only the drawing: keeping them apart means
//  a rendering change cannot quietly alter the science.

import BoffinCore
import SwiftUI

public struct SequenceLogoView: View {
    /// What the glyph heights represent.
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        /// Height is `p(aa) * (log2(20) - H)`: the classic information-content
        /// logo, everything above the axis.
        case informationContent
        /// Height is the delta-LLR itself: tolerated substitutions above the
        /// axis, deleterious below. Not a conventional logo, and useful because
        /// it shows sign, which an information logo cannot.
        case deltaLLR

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .informationContent: "Information content"
            case .deltaLLR: "Delta LLR"
            }
        }
        public var unit: String {
            switch self {
            case .informationContent: "bits"
            case .deltaLLR: "log-likelihood ratio"
            }
        }
    }

    private let matrix: LLRMatrix
    private let mode: Mode
    private let style: TrackRulerStyle
    @Binding private var pinned: Int?

    @State private var columnWidth: CGFloat = 22
    @State private var zoomAnchor: CGFloat = 22

    public static let height: CGFloat = 120
    public static let accessibilityIdentifier = "boffin.sequence-logo"

    public init(
        matrix: LLRMatrix,
        mode: Mode = .informationContent,
        pinned: Binding<Int?>,
        style: TrackRulerStyle = TrackRulerStyle()
    ) {
        self.matrix = matrix
        self.mode = mode
        self._pinned = pinned
        self.style = style
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(
                    width: max(CGFloat(matrix.columnCount) * columnWidth, 1),
                    height: Self.height
                )
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { event in
                        let column = Int(event.location.x / columnWidth)
                        pinned =
                            (column >= 0 && column < matrix.columnCount)
                            ? matrix.positions[column] : nil
                    })
        }
        .frame(height: Self.height)
        .gesture(
            MagnifyGesture()
                .onChanged { columnWidth = min(max(zoomAnchor * $0.magnification, 4), 44) }
                .onEnded { _ in zoomAnchor = columnWidth }
        )
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .accessibilityLabel("Sequence logo, \(mode.displayName)")
    }

    /// Softmax over a column's delta-LLR values, giving each residue's share.
    ///
    /// The scores are log-ratios against the wild type, so exponentiating and
    /// normalising recovers the model's distribution up to a constant, which is
    /// exactly what the logo needs.
    private func probabilities(for column: Int) -> [Double] {
        let scores = matrix.values[column]
        let maximum = scores.max() ?? 0
        let exponentials = scores.map { Foundation.exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total > 0 else {
            return [Double](repeating: 1.0 / Double(scores.count), count: scores.count)
        }
        return exponentials.map { $0 / total }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard matrix.columnCount > 0, columnWidth > 0 else { return }
        let visibleColumns = min(matrix.columnCount, Int(size.width / columnWidth) + 1)
        guard visibleColumns > 0 else { return }

        switch mode {
        case .informationContent:
            drawInformationLogo(in: &context, columns: 0..<visibleColumns)
        case .deltaLLR:
            drawSignedLogo(in: &context, columns: 0..<visibleColumns)
        }
    }

    private func drawInformationLogo(in context: inout GraphicsContext, columns: Range<Int>) {
        // Scale to the theoretical maximum, log2(20), not to the tallest column
        // in this protein. A per-protein scale would make two logos
        // incomparable while looking identical.
        let maximumBits = InformationContent.maximumBits

        for column in columns {
            let p = probabilities(for: column)
            let bits = InformationContent.bits(p)
            guard bits > 0 else { continue }

            let order = p.indices.sorted { p[$0] < p[$1] }
            var y = Self.height
            for index in order {
                let share = p[index] * bits
                let glyphHeight = Self.height * CGFloat(share / maximumBits)
                guard glyphHeight > 0.4 else { continue }
                y -= glyphHeight
                drawGlyph(
                    matrix.rows[index], in: &context,
                    rect: CGRect(
                        x: CGFloat(column) * columnWidth, y: y,
                        width: columnWidth, height: glyphHeight))
            }
        }
    }

    private func drawSignedLogo(in context: inout GraphicsContext, columns: Range<Int>) {
        let bound = matrix.symmetricBound
        let midline = Self.height / 2
        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: midline))
                path.addLine(
                    to: CGPoint(x: CGFloat(columns.upperBound) * columnWidth, y: midline))
            },
            with: .color(style.axis.opacity(0.5)), lineWidth: 0.5)

        for column in columns {
            let scores = matrix.values[column]
            var above = midline
            var below = midline
            for (index, score) in scores.enumerated() where abs(score) > 0.05 {
                let glyphHeight = midline * CGFloat(min(abs(score) / bound, 1))
                guard glyphHeight > 0.4 else { continue }
                let rect: CGRect
                if score > 0 {
                    above -= glyphHeight
                    rect = CGRect(
                        x: CGFloat(column) * columnWidth, y: above,
                        width: columnWidth, height: glyphHeight)
                } else {
                    rect = CGRect(
                        x: CGFloat(column) * columnWidth, y: below,
                        width: columnWidth, height: glyphHeight)
                    below += glyphHeight
                }
                drawGlyph(matrix.rows[index], in: &context, rect: rect)
            }
        }
    }

    /// Draw one residue letter stretched to fill its rect.
    ///
    /// Non-uniform scaling is the point of a logo: the glyph's height carries
    /// the value, so it is deliberately distorted rather than scaled evenly.
    private func drawGlyph(
        _ acid: AminoAcid, in context: inout GraphicsContext, rect: CGRect
    ) {
        let text = Text(String(acid.code))
            .font(.system(size: 40, weight: .bold, design: .monospaced))
            .foregroundColor(style.categoryColour(String(acid.code)))
        let resolved = context.resolve(text)
        let natural = resolved.measure(in: CGSize(width: 200, height: 200))
        guard natural.width > 0, natural.height > 0 else { return }

        context.drawLayer { layer in
            layer.translateBy(x: rect.minX, y: rect.minY)
            layer.scaleBy(x: rect.width / natural.width, y: rect.height / natural.height)
            layer.draw(resolved, at: .zero, anchor: .topLeading)
        }
    }
}
