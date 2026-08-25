//  InteractionDiagramTests.swift
//  BoffinChartsTests
//
//  The layout is pure and separated from the drawing so it can be tested without
//  rendering. What is checked is stability and legibility: two figures of the
//  same site must be comparable, and the diagram must be readable by VoiceOver.

import Testing

@testable import BoffinCharts

@Suite("Interaction diagram")
struct InteractionDiagramTests {

    /// A force-directed layout would look more like the published figures and
    /// would move a residue between renders of the same structure, which makes
    /// two figures of one site impossible to compare. A circle is boring,
    /// stable and reproducible, and this pins that.
    @Test("The layout is deterministic")
    func deterministic() {
        #expect(InteractionDiagram.positions(count: 6) == InteractionDiagram.positions(count: 6))
        #expect(InteractionDiagram.positions(count: 0).isEmpty)
        #expect(InteractionDiagram.positions(count: 1).count == 1)
    }

    @Test("Contacts sit on a circle inside the canvas, starting at the top")
    func geometry() {
        let places = InteractionDiagram.positions(count: 8)
        #expect(places.count == 8)
        for place in places {
            #expect(place.x > 0 && place.x < 1)
            #expect(place.y > 0 && place.y < 1)
            // On the circle: the radius from the centre is constant.
            let radius = ((place.x - 0.5) * (place.x - 0.5) + (place.y - 0.5) * (place.y - 0.5))
                .squareRoot()
            #expect(abs(radius - 0.36) < 1e-9, "radius \(radius)")
        }
        // The first is at the top, which is where a reader starts.
        #expect(abs(places[0].x - 0.5) < 1e-9)
        #expect(places[0].y < 0.5)
    }

    @Test("Every kind is visually distinct without relying on colour alone")
    func printSafe() {
        // A figure gets printed in grey, and it must still be readable, so
        // dashing carries the distinction that colour also carries.
        let dashed = DiagramKind.allCases.filter(\.isDashed)
        let solid = DiagramKind.allCases.filter { !$0.isDashed }
        #expect(!dashed.isEmpty && !solid.isEmpty)
        // And every kind has a name for the legend and for VoiceOver.
        for kind in DiagramKind.allCases {
            #expect(!kind.name.isEmpty)
        }
        #expect(Set(DiagramKind.allCases.map(\.name)).count == DiagramKind.allCases.count)
    }

    /// Not optional polish: a diagram nobody can hear is a diagram half the
    /// point of which is missing.
    @Test("VoiceOver gets the contacts, their kinds and their distances")
    func accessibility() {
        let description = InteractionDiagram.describe([
            DiagramContact(label: "LEU83", kinds: [.hydrogenBond], distance: 2.9),
            DiagramContact(
                label: "LYS33", kinds: [.saltBridge, .hydrophobic], distance: 3.4),
        ])
        #expect(description.contains("LEU83"))
        #expect(description.contains("Hydrogen bond"))
        #expect(description.contains("2.9 angstroms"))
        #expect(description.contains("Salt bridge and Hydrophobic"))
    }

    @Test("An empty diagram says so rather than reading as silence")
    func empty() {
        #expect(InteractionDiagram.describe([]) == "No contacts.")
    }
}
