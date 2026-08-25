//  InteractionDiagram.swift
//  BoffinCharts
//
//  The 2D interaction diagram: the PLIP-style figure, drawn natively.
//
//  Native `Canvas` rather than a web chart, for the same reason as every other
//  chart here: it has to be exportable at figure resolution, it has to be
//  legible in dark mode, and it has to work with VoiceOver. None of those come
//  free from an image handed over by JavaScript.
//
//  The layout is deliberately simple and says so
//  ---------------------------------------------
//  Contacted residues are placed on a circle around the ligand, ordered by
//  residue number. A force-directed layout would look more like the published
//  figures and would move a residue's position between renders of the same
//  structure, which makes two figures of the same site impossible to compare.
//  A circle is boring, stable, and reproducible.

import BoffinCore
import SwiftUI

/// One residue on the diagram and how it contacts the ligand.
public struct DiagramContact: Sendable, Hashable, Identifiable {
    public let label: String
    /// Interaction kinds present, in a stable order for the legend.
    public let kinds: [DiagramKind]
    /// Closest approach in angstroms, shown on the connector.
    public let distance: Double

    public var id: String { label }

    public init(label: String, kinds: [DiagramKind], distance: Double) {
        self.label = label
        self.kinds = kinds
        self.distance = distance
    }
}

/// The interaction kinds the diagram can draw, with their colours.
///
/// A separate enum from `BoffinStructure`'s so the chart package does not
/// depend on it: BoffinCharts sees BoffinCore and nothing else, which is the
/// dependency rule, and the app maps between them.
public enum DiagramKind: String, Sendable, Hashable, CaseIterable {
    case hydrophobic
    case hydrogenBond
    case saltBridge
    case metalCoordination
    case halogenBond

    public var name: String {
        switch self {
        case .hydrophobic: "Hydrophobic"
        case .hydrogenBond: "Hydrogen bond"
        case .saltBridge: "Salt bridge"
        case .metalCoordination: "Metal"
        case .halogenBond: "Halogen bond"
        }
    }

    /// Distinguishable in dark mode, in print, and to the most common forms of
    /// colour blindness: no red against green pairing.
    public var colour: Color {
        switch self {
        case .hydrophobic: Color(red: 0.55, green: 0.55, blue: 0.58)
        case .hydrogenBond: Color(red: 0.27, green: 0.50, blue: 0.97)
        case .saltBridge: Color(red: 0.90, green: 0.49, blue: 0.13)
        case .metalCoordination: Color(red: 0.55, green: 0.34, blue: 0.75)
        case .halogenBond: Color(red: 0.00, green: 0.60, blue: 0.53)
        }
    }

    /// Dashed for the directional interactions, solid for the rest, so the
    /// figure survives being printed in grey.
    public var isDashed: Bool {
        switch self {
        case .hydrogenBond, .saltBridge, .halogenBond, .metalCoordination: true
        case .hydrophobic: false
        }
    }
}

public struct InteractionDiagram: View {
    private let ligandName: String
    private let contacts: [DiagramContact]

    public init(ligandName: String, contacts: [DiagramContact]) {
        self.ligandName = ligandName
        self.contacts = contacts
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .accessibilityElement()
            .accessibilityLabel("Interaction diagram for \(ligandName)")
            .accessibilityValue(Self.describe(contacts))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// What VoiceOver reads. Not optional polish: a diagram nobody can hear is a
    /// diagram half the point of which is missing.
    ///
    /// A `nonisolated static` function rather than a property on the view.
    /// `View` conformance carries main-actor isolation, and a test calling an
    /// isolated member off the main actor takes the process down with signal 5
    /// rather than failing: the run reports every test STARTING and none
    /// finishing, which reads like a hang.
    public nonisolated static func describe(_ contacts: [DiagramContact]) -> String {
        guard !contacts.isEmpty else { return "No contacts." }
        return contacts.map { contact in
            "\(contact.label), \(contact.kinds.map(\.name).joined(separator: " and ")), "
                + String(format: "%.1f angstroms", contact.distance)
        }.joined(separator: ". ")
    }

    /// Where each contact sits, as a fraction of the canvas.
    ///
    /// Pure, and separated from the drawing so the layout can be tested without
    /// rendering anything.
    nonisolated static func positions(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            // Start at the top and go clockwise, which is how a reader scans a
            // radial figure.
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: 0.5 + 0.36 * cos(angle), y: 0.5 + 0.36 * sin(angle))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let places = Self.positions(count: contacts.count)

        for (index, contact) in contacts.enumerated() {
            let point = CGPoint(
                x: places[index].x * size.width, y: places[index].y * size.height)

            // One connector per kind, fanned slightly so two interactions
            // between the same pair are both visible rather than one hiding
            // under the other.
            for (offset, kind) in contact.kinds.enumerated() {
                let shift = CGFloat(offset - (contact.kinds.count - 1)) * 2
                var path = Path()
                path.move(to: CGPoint(x: centre.x + shift, y: centre.y + shift))
                path.addLine(to: CGPoint(x: point.x + shift, y: point.y + shift))
                context.stroke(
                    path, with: .color(kind.colour),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: kind.isDashed ? [4, 3] : []))
            }

            let label = Text(contact.label)
                .font(.system(size: 10, design: .monospaced))
            context.draw(label, at: point)

            let distance = Text(String(format: "%.1f", contact.distance))
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            context.draw(
                distance,
                at: CGPoint(
                    x: (centre.x + point.x) / 2, y: (centre.y + point.y) / 2 - 6))
        }

        let ligand = Text(ligandName).font(.system(size: 12, weight: .semibold))
        context.draw(ligand, at: centre)
    }
}
