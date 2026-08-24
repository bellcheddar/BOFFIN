//  TrackRulerView.swift
//  BoffinCharts
//
//  The single scrollable ruler that every analytical output stacks on. Tabs are
//  filters over this view, not separate widgets.
//
//  Drawing is virtualised: at 20 points per residue a 30,000-residue titin
//  construct is 600,000 points wide, and drawing all of it every frame would
//  miss the 120 Hz budget by orders of magnitude. Only the residues actually on
//  screen are drawn, plus a small overscan so a fast flick does not reveal
//  blank space.
//
//  Colours arrive through `TrackRulerStyle` rather than being imported. The
//  module dependency rule allows BoffinCharts to see BoffinCore only, so the
//  brand palette is injected by the app rather than reached for here. That is
//  the rule working as intended: the renderer does not need to know what navy
//  means.

import BoffinCore
import SwiftUI

/// Colours and metrics for the ruler. Defaults are deliberately neutral: the
/// app supplies the branded values.
public struct TrackRulerStyle: Sendable {
    public var background: Color
    public var axis: Color
    public var text: Color
    public var mutedText: Color
    public var selection: Color
    public var trackFill: Color

    /// Resolves a categorical track value (for example a DSSP code) to a colour.
    public var categoryColour: @Sendable (String) -> Color

    /// Resolves a normalised 0 to 1 value on a sequential scale.
    public var sequentialColour: @Sendable (Double) -> Color

    /// Resolves a signed value on a diverging scale, where 0 is the midpoint.
    public var divergingColour: @Sendable (Double) -> Color

    public init(
        background: Color = .clear,
        axis: Color = .secondary,
        text: Color = .primary,
        mutedText: Color = .secondary,
        selection: Color = .accentColor,
        trackFill: Color = .accentColor,
        categoryColour: @escaping @Sendable (String) -> Color = { _ in .gray },
        sequentialColour: @escaping @Sendable (Double) -> Color = { value in
            Color(hue: 0.6, saturation: 0.2 + 0.6 * value, brightness: 0.9 - 0.3 * value)
        },
        divergingColour: @escaping @Sendable (Double) -> Color = { value in
            value < 0 ? .red.opacity(min(1, -value)) : .blue.opacity(min(1, value))
        }
    ) {
        self.background = background
        self.axis = axis
        self.text = text
        self.mutedText = mutedText
        self.selection = selection
        self.trackFill = trackFill
        self.categoryColour = categoryColour
        self.sequentialColour = sequentialColour
        self.divergingColour = divergingColour
    }
}

/// Layout constants, kept together so the ruler's geometry is described in one
/// place rather than scattered through the drawing code.
public enum TrackRulerMetrics {
    /// Points per residue at the most zoomed out. Below this, individual
    /// residues are sub-pixel and the ruler becomes a density plot.
    public static let minimumResidueWidth: CGFloat = 1.5
    /// Points per residue at the most zoomed in.
    public static let maximumResidueWidth: CGFloat = 28
    public static let defaultResidueWidth: CGFloat = 12

    /// Below this width, one-letter codes are not drawn: glyphs would overlap
    /// into an unreadable smear that still costs a text layout per residue.
    public static let letterVisibilityThreshold: CGFloat = 7

    public static let sequenceRowHeight: CGFloat = 22
    public static let axisRowHeight: CGFloat = 18
    public static let trackRowHeight: CGFloat = 28
    public static let trackSpacing: CGFloat = 4

    /// Residues drawn beyond each edge of the viewport, so a fast scroll does
    /// not expose undrawn space before the next frame.
    public static let overscanResidues = 16
}

/// The scrollable ruler.
public struct TrackRulerView: View {
    /// Stable identifier for UI tests.
    public static let accessibilityIdentifier = "boffin.residue-ruler"

    private let sequence: ProteinSequence
    private let tracks: [AnyResidueTrack]
    private let style: TrackRulerStyle

    @Binding private var selection: ClosedRange<Int>?

    @State private var residueWidth: CGFloat = TrackRulerMetrics.defaultResidueWidth
    @State private var zoomAnchor: CGFloat = TrackRulerMetrics.defaultResidueWidth
    @State private var visibleRange: Range<Int> = 0..<0
    @State private var dragOrigin: Int?

    public init(
        sequence: ProteinSequence,
        tracks: [AnyResidueTrack],
        selection: Binding<ClosedRange<Int>?>,
        style: TrackRulerStyle = TrackRulerStyle()
    ) {
        self.sequence = sequence
        self.tracks = tracks
        self.style = style
        self._selection = selection
    }

    private var contentWidth: CGFloat { CGFloat(sequence.count) * residueWidth }

    private var contentHeight: CGFloat {
        TrackRulerMetrics.axisRowHeight + TrackRulerMetrics.sequenceRowHeight
            + CGFloat(tracks.count)
            * (TrackRulerMetrics.trackRowHeight + TrackRulerMetrics.trackSpacing)
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: max(contentWidth, 1), height: contentHeight)
            .contentShape(Rectangle())
            .gesture(selectionGesture)
        }
        .background(style.background)
        .modifier(VisibleRangeReporter { bounds in updateVisibleRange(from: bounds) })
        .gesture(zoomGesture)
        // An explicit identifier as well as a label: the label is what
        // VoiceOver speaks, the identifier is what UI tests query, and relying
        // on the label for both makes the test brittle against copy changes.
        .accessibilityIdentifier(TrackRulerView.accessibilityIdentifier)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Residue ruler")
        .accessibilityValue(accessibilityDescription)
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                residueWidth = (zoomAnchor * value.magnification)
                    .clamped(
                        to: TrackRulerMetrics
                            .minimumResidueWidth...TrackRulerMetrics.maximumResidueWidth)
            }
            .onEnded { _ in zoomAnchor = residueWidth }
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let index = residueIndex(atX: value.location.x)
                let origin = dragOrigin ?? index
                dragOrigin = origin
                selection = min(origin, index)...max(origin, index)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func residueIndex(atX x: CGFloat) -> Int {
        TrackRulerGeometry.residueIndex(
            atX: x, residueWidth: residueWidth, residueCount: sequence.count)
    }

    private func updateVisibleRange(from bounds: ClosedRange<CGFloat>) {
        visibleRange = TrackRulerGeometry.visibleRange(
            viewport: bounds, residueWidth: residueWidth, residueCount: sequence.count)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Before the first scroll-geometry callback arrives, visibleRange is
        // empty. Falling back to the whole sequence there would draw everything
        // on the first frame, which is exactly the cost virtualisation exists to
        // avoid, so bound the fallback to what could fit on screen instead.
        let range: Range<Int>
        if visibleRange.isEmpty {
            let fits = residueWidth > 0 ? Int(size.width / residueWidth) + 1 : 0
            range = 0..<min(sequence.count, max(fits, 1))
        } else {
            range = visibleRange
        }
        guard !range.isEmpty else { return }

        drawSelection(in: &context, range: range)
        drawAxis(in: &context, range: range)
        drawSequence(in: &context, range: range)

        var y = TrackRulerMetrics.axisRowHeight + TrackRulerMetrics.sequenceRowHeight
        for track in tracks {
            drawTrack(track, in: &context, range: range, y: y)
            y += TrackRulerMetrics.trackRowHeight + TrackRulerMetrics.trackSpacing
        }
    }

    private func drawSelection(in context: inout GraphicsContext, range: Range<Int>) {
        guard let selection else { return }
        let x = CGFloat(selection.lowerBound) * residueWidth
        let width = CGFloat(selection.count) * residueWidth
        context.fill(
            Path(CGRect(x: x, y: 0, width: width, height: contentHeight)),
            with: .color(style.selection.opacity(0.18)))
    }

    private func drawAxis(in context: inout GraphicsContext, range: Range<Int>) {
        // Choose a tick spacing that stays readable at every zoom rather than
        // drawing a label per residue and letting them collide.
        let step = TrackRulerGeometry.residuesPerTick(residueWidth: residueWidth)

        let firstTick = (range.lowerBound / step) * step
        var position = firstTick
        while position < range.upperBound {
            defer { position += step }
            guard position >= 0, position < sequence.count else { continue }
            let x = CGFloat(position) * residueWidth
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: TrackRulerMetrics.axisRowHeight - 5))
                    path.addLine(to: CGPoint(x: x, y: TrackRulerMetrics.axisRowHeight))
                },
                with: .color(style.axis),
                lineWidth: 1)

            // Author numbering when the sequence came from a structure,
            // otherwise one-based position. These are not interchangeable.
            let residue = sequence.residues[position]
            let label = residue.authorNumber ?? (position + 1)
            let text = Text(String(label)).font(.system(size: 9, design: .monospaced))
            context.draw(
                text.foregroundColor(style.mutedText),
                at: CGPoint(x: x + 2, y: 6),
                anchor: .leading)
        }
    }

    private func drawSequence(in context: inout GraphicsContext, range: Range<Int>) {
        let y = TrackRulerMetrics.axisRowHeight
        guard residueWidth >= TrackRulerMetrics.letterVisibilityThreshold else {
            // Too dense for glyphs: draw a compact band so the sequence still
            // reads as present rather than as a gap in the layout.
            context.fill(
                Path(
                    CGRect(
                        x: CGFloat(range.lowerBound) * residueWidth, y: y + 6,
                        width: CGFloat(range.count) * residueWidth,
                        height: TrackRulerMetrics.sequenceRowHeight - 12)),
                with: .color(style.mutedText.opacity(0.25)))
            return
        }

        let fontSize = min(residueWidth * 0.9, 15)
        for index in range {
            let residue = sequence.residues[index]
            let x = CGFloat(index) * residueWidth + residueWidth / 2
            let colour = residue.identity.isScorable ? style.text : style.mutedText
            let text = Text(String(residue.code))
                .font(.system(size: fontSize, design: .monospaced))
            context.draw(
                text.foregroundColor(colour),
                at: CGPoint(x: x, y: y + TrackRulerMetrics.sequenceRowHeight / 2),
                anchor: .center)
        }
    }

    private func drawTrack(
        _ track: AnyResidueTrack,
        in context: inout GraphicsContext,
        range: Range<Int>,
        y: CGFloat
    ) {
        let height = TrackRulerMetrics.trackRowHeight

        switch track.values {
        case .continuous(let values):
            drawContinuous(values, in: &context, range: range, y: y, height: height, track: track)

        case .categorical(let values):
            for index in range where index < values.count {
                guard let category = values[index] else { continue }
                let x = CGFloat(index) * residueWidth
                context.fill(
                    Path(CGRect(x: x, y: y + 4, width: residueWidth, height: height - 8)),
                    with: .color(style.categoryColour(category)))
            }

        case .spans(let spans):
            for span in spans {
                guard span.end >= range.lowerBound, span.start < range.upperBound else { continue }
                let x = CGFloat(span.start) * residueWidth
                let width = CGFloat(span.end - span.start + 1) * residueWidth
                context.fill(
                    Path(
                        roundedRect: CGRect(x: x, y: y + 6, width: width, height: height - 12),
                        cornerRadius: 3),
                    with: .color(style.trackFill.opacity(0.75)))
            }

        case .matrix(let rows, let columns):
            let cellHeight = height / CGFloat(max(rows.count, 1))
            for index in range where index < columns.count {
                let x = CGFloat(index) * residueWidth
                for (row, value) in columns[index].enumerated() {
                    guard let value else { continue }
                    context.fill(
                        Path(
                            CGRect(
                                x: x, y: y + CGFloat(row) * cellHeight,
                                width: residueWidth, height: cellHeight)),
                        with: .color(style.divergingColour(value)))
                }
            }
        }
    }

    private func drawContinuous(
        _ values: [Double?],
        in context: inout GraphicsContext,
        range: Range<Int>,
        y: CGFloat,
        height: CGFloat,
        track: AnyResidueTrack
    ) {
        // A continuous track may be sequential (a bounded probability) or
        // diverging about a midpoint (hydropathy, which is signed). Handling
        // only one of them draws an empty row for the other, which reads as
        // "no data" rather than as a missing case.
        switch track.colourScheme {
        case .sequential(let minimum, let maximum):
            let span = maximum - minimum
            guard span > 0 else { return }
            for index in range where index < values.count {
                guard let value = values[index] else { continue }
                let normalised = ((value - minimum) / span).clamped(to: 0...1)
                let barHeight = height * CGFloat(normalised)
                let x = CGFloat(index) * residueWidth
                context.fill(
                    Path(
                        CGRect(
                            x: x, y: y + height - barHeight,
                            width: residueWidth, height: barHeight)),
                    with: .color(style.sequentialColour(normalised)))
            }

        case .diverging(let minimum, let mid, let maximum):
            // Drawn from a central baseline so sign is visible at a glance:
            // a hydropathy plot that renders as bars from the bottom hides the
            // one thing it exists to show.
            let extent = max(maximum - mid, mid - minimum)
            guard extent > 0 else { return }
            let baseline = y + height / 2
            for index in range where index < values.count {
                guard let value = values[index] else { continue }
                let normalised = ((value - mid) / extent).clamped(to: -1...1)
                let barHeight = (height / 2) * CGFloat(abs(normalised))
                let x = CGFloat(index) * residueWidth
                let top = normalised >= 0 ? baseline - barHeight : baseline
                context.fill(
                    Path(CGRect(x: x, y: top, width: residueWidth, height: barHeight)),
                    with: .color(style.divergingColour(normalised)))
            }
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: CGFloat(range.lowerBound) * residueWidth, y: baseline))
                    path.addLine(
                        to: CGPoint(x: CGFloat(range.upperBound) * residueWidth, y: baseline))
                },
                with: .color(style.axis.opacity(0.4)),
                lineWidth: 0.5)

        case .categorical, .solid:
            // Neither describes how to scale a continuous value, so nothing is
            // drawn rather than a plot with an invented domain.
            return
        }
    }

    private var accessibilityDescription: String {
        var description = "\(sequence.count) residues"
        if let selection {
            description += ", selection \(selection.lowerBound + 1) to \(selection.upperBound + 1)"
        }
        if !tracks.isEmpty {
            description += ", \(tracks.count) tracks: "
            description += tracks.map(\.title).joined(separator: ", ")
        }
        return description
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// Reports the horizontally visible span of a scroll view, so the ruler can
/// draw only the residues actually on screen.
///
/// `onScrollGeometryChange` needs iOS 18 / macOS 15. The app targets iOS 26 and
/// always has it; the availability guard exists because the packages also build
/// for macOS 14 so their tests can run on the host without a simulator. On that
/// path the ruler falls back to drawing a viewport-sized window from the start
/// of the sequence, which is correct for an unscrolled view and is never seen
/// by a user, since nothing renders during host unit tests.
private struct VisibleRangeReporter: ViewModifier {
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
