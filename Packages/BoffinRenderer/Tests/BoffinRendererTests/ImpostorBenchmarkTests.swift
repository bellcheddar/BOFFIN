//  ImpostorBenchmarkTests.swift
//  BoffinRendererTests
//
//  Phase 12's plan says the renderer is to be "benchmarked against Mol\\*
//  rather than assumed to beat it". This is that benchmark.
//
//  The number to beat is 100,000 atoms: `StructureViewer.coarseAboveAtoms`,
//  above which the shipped viewer drops to a backbone trace because, in its
//  own words, a cartoon at that size "does not render slowly, it stops
//  responding". A renderer that cannot hold interactive frame times past that
//  point would buy nothing.

import BoffinStructure
import Foundation
import Testing

@testable import BoffinRenderer

private var metalAvailable: Bool { (try? ImpostorRenderer()) != nil }

/// A plausible protein-shaped cloud rather than a uniform cube.
///
/// Uniform random points spread the atoms evenly, which is the easy case for a
/// depth buffer: real structures are dense in the middle and produce far more
/// overdraw, which is what actually costs.
private func cloud(_ count: Int, seed: UInt64 = 42) -> [RendererAtom] {
    var state = seed
    func random() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 33) / Float(UInt32.max) - 0.5
    }
    let colours: [SIMD3<Float>] = [
        [0.35, 0.55, 0.95], [0.90, 0.35, 0.30], [0.35, 0.75, 0.45],
        [0.95, 0.80, 0.25], [0.75, 0.75, 0.78],
    ]
    let radius = Float(count).cubeRoot() * 1.4
    return (0..<count).map { index in
        // Gaussian-ish by summing three uniforms, so density falls off from
        // the centre the way a folded protein's does.
        let x = (random() + random() + random()) * radius
        let y = (random() + random() + random()) * radius
        let z = (random() + random() + random()) * radius
        return RendererAtom(
            position: SIMD3(x, y, z), radius: 1.7,
            colour: colours[index % colours.count])
    }
}

extension Float {
    fileprivate func cubeRoot() -> Float { pow(self, 1.0 / 3.0) }
}

@Suite("Impostor renderer")
struct ImpostorBenchmarkTests {

    @Test("A frame renders at all", .enabled(if: metalAvailable))
    func rendersAFrame() throws {
        let renderer = try ImpostorRenderer()
        let time = try renderer.renderFrame(atoms: cloud(1000))
        #expect(time > 0, "a frame that takes no time was not drawn")
    }

    @Test("An empty structure is not an error", .enabled(if: metalAvailable))
    func emptyIsFine() throws {
        let renderer = try ImpostorRenderer()
        #expect(try renderer.renderFrame(atoms: []) == 0)
    }

    @Test(
        "Frame time against atom count, past the viewer's guardrail",
        .enabled(if: metalAvailable), .timeLimit(.minutes(5)))
    func benchmark() throws {
        let renderer = try ImpostorRenderer()
        var results: [(Int, Double)] = []

        for count in [1_000, 10_000, 50_000, 100_000, 250_000, 500_000] {
            let atoms = cloud(count)
            // One frame discarded: the first allocates buffers and warms the
            // pipeline, and timing it would report setup as if it were frame
            // cost.
            _ = try renderer.renderFrame(atoms: atoms)
            var samples: [Double] = []
            for _ in 0..<5 { samples.append(try renderer.renderFrame(atoms: atoms)) }
            let median = samples.sorted()[samples.count / 2] * 1000
            results.append((count, median))
            print(
                String(
                    format: "BENCH %7d atoms  %6.2f ms  %5.0f fps",
                    count, median, 1000 / max(median, 0.001)))
        }

        // The claim being tested, stated as an assertion rather than left in
        // the output for someone to interpret: at the size where the shipped
        // viewer gives up, this must still be interactive.
        let atGuardrail = try #require(results.first { $0.0 == 100_000 })
        let detail = String(format: "%.2f ms at 100k atoms", atGuardrail.1)
        #expect(atGuardrail.1 < 16.7, "not interactive at the guardrail: \(detail)")
    }
}

@Suite("Impostor renderer, on a real structure")
struct RealStructureBenchmarkTests {

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/structures")
    }

    private func store(_ name: String) throws -> AtomStore {
        try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name))))
    }

    @Test(
        "The ribosome, which is what the guardrail exists for",
        .enabled(if: metalAvailable), .timeLimit(.minutes(5)))
    func ribosome() throws {
        // 7K00 is the E. coli 70S ribosome and the reason the shipped viewer
        // has a guardrail at all. Synthetic clouds are an easier case: real
        // structures are denser in the middle, which is where overdraw costs.
        let atoms = RendererAtom.all(from: try store("7k00.bcif"))
        let renderer = try ImpostorRenderer()
        _ = try renderer.renderFrame(atoms: atoms)
        var samples: [Double] = []
        for _ in 0..<5 { samples.append(try renderer.renderFrame(atoms: atoms)) }
        let median = samples.sorted()[samples.count / 2] * 1000
        print(
            String(
                format: "BENCH ribosome %d atoms  %.2f ms  %.0f fps",
                atoms.count, median, 1000 / max(median, 0.001)))
        #expect(atoms.count > 100_000, "this fixture should be past the guardrail")
        let detail = String(format: "%.2f ms on the ribosome", median)
        #expect(median < 16.7, "\(detail)")
    }

    @Test("A small structure for comparison", .enabled(if: metalAvailable))
    func ubiquitin() throws {
        let atoms = RendererAtom.all(from: try store("1ubq.bcif"))
        let renderer = try ImpostorRenderer()
        _ = try renderer.renderFrame(atoms: atoms)
        let median = try renderer.renderFrame(atoms: atoms) * 1000
        print(String(format: "BENCH ubiquitin %d atoms  %.2f ms", atoms.count, median))
    }
}
