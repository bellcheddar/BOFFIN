//  ConstructSolverTests.swift
//  BoffinCoreTests
//
//  The solver's hard constraints are the whole point of it, so they are tested
//  as prohibitions rather than as preferences: a construct that bisects a
//  catalytic motif must be ABSENT from the output, not merely ranked low.

import Testing

@testable import BoffinCore

@Suite("Construct solver")
struct ConstructSolverTests {

    /// A 300-residue protein: 40 disordered residues at each end, an ordered
    /// core, and a motif in the middle of it.
    private func standard() -> (disordered: [Bool], constraints: [ConstructConstraint]) {
        var disordered = [Bool](repeating: false, count: 300)
        for index in 0..<40 { disordered[index] = true }
        for index in 260..<300 { disordered[index] = true }
        return (
            disordered,
            [
                ConstructConstraint(kind: .motif, range: 140...145, label: "HRD")
            ]
        )
    }

    @Test("The best proposal trims the disordered termini")
    func trimsDisorder() {
        let (disordered, constraints) = standard()
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: disordered, constraints: constraints)
        let best = try? #require(result.proposals.first)
        #expect(best?.range == 40...259)
        #expect(best?.rationale.contains { $0.contains("80 predicted disordered") } == true)
    }

    @Test("No proposal ever cuts through a motif")
    func neverCutsAMotif() {
        let (disordered, _) = standard()
        // A motif placed where a naive trim would land: right at the first
        // ordered residue.
        let constraints = [
            ConstructConstraint(kind: .motif, range: 38...44, label: "G-loop")
        ]
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: disordered, constraints: constraints,
            limit: 50)
        #expect(!result.proposals.isEmpty)
        for proposal in result.proposals {
            #expect(
                proposal.range.lowerBound <= 38 && proposal.range.upperBound >= 44,
                "\(proposal.description) does not keep the G-loop whole")
        }
    }

    @Test("A transmembrane span is kept whole, never bisected")
    func keepsTransmembraneSpans() {
        var disordered = [Bool](repeating: false, count: 400)
        for index in 0..<30 { disordered[index] = true }
        for index in 370..<400 { disordered[index] = true }
        let constraints = (0..<7).map { index in
            ConstructConstraint(
                kind: .transmembrane,
                range: (40 + index * 45)...(60 + index * 45),
                label: "TM\(index + 1)")
        }
        let result = ConstructSolver.propose(
            residueCount: 400, disordered: disordered, constraints: constraints,
            limit: 50)
        #expect(!result.proposals.isEmpty)
        for proposal in result.proposals {
            for constraint in constraints {
                #expect(
                    proposal.range.lowerBound <= constraint.range.lowerBound
                        && proposal.range.upperBound >= constraint.range.upperBound,
                    "\(proposal.description) truncates \(constraint.label)")
            }
        }
    }

    /// A signal peptide is the one annotated region a construct is ALLOWED to
    /// drop, and usually should.
    @Test("A signal peptide may be removed, and removing it is preferred")
    func removesSignalPeptide() {
        var disordered = [Bool](repeating: false, count: 300)
        for index in 0..<22 { disordered[index] = true }
        let constraints = [
            ConstructConstraint(kind: .signalPeptide, range: 0...21, label: "signal"),
            ConstructConstraint(kind: .motif, range: 100...110, label: "catalytic"),
        ]
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: disordered, constraints: constraints)
        let best = try? #require(result.proposals.first)
        #expect(best?.range.lowerBound == 22)
        #expect(
            best?.rationale.contains { $0.contains("signal peptide") } == true)
    }

    @Test("Deposited boundaries are preferred and the count is reported")
    func precedentWins() {
        let (disordered, constraints) = standard()
        // A deposited construct that starts ten residues later than the maximal
        // trim. Three entries agree on it, which should outweigh the ten
        // disordered residues the maximal trim removes.
        let deposited = Array(repeating: 50...255, count: 3)
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: disordered, constraints: constraints,
            precedent: deposited)
        let best = try? #require(result.proposals.first)
        #expect(best?.range == 50...255)
        #expect(best?.precedentCount == 3)
        #expect(best?.rationale.contains { $0.contains("deposited") } == true)
    }

    @Test("A fully disordered protein is refused, with the reason")
    func refusesDisorderedProtein() {
        // Alpha synuclein is the fixture this exists for: 140 residues and no
        // folded domain to truncate to.
        let disordered = [Bool](repeating: true, count: 140)
        let result = ConstructSolver.propose(
            residueCount: 140, disordered: disordered, constraints: [])
        guard case .declined(let reason) = result else {
            Issue.record("expected a refusal, got \(result.proposals.count) proposals")
            return
        }
        #expect(reason.contains("0%"))
        #expect(reason.lowercased().contains("no domain"))
    }

    @Test("No disorder prediction is refused rather than assumed to be ordered")
    func refusesWithoutADisorderTrack() {
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: [], constraints: [])
        guard case .declined(let reason) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("No disorder prediction"))
    }

    @Test("A sequence too short to express is refused")
    func refusesShortSequence() {
        let result = ConstructSolver.propose(
            residueCount: 20, disordered: [Bool](repeating: false, count: 20),
            constraints: [])
        guard case .declined(let reason) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("20 residues"))
    }

    @Test("Constraints that cannot all be kept produce a refusal, not a compromise")
    func refusesImpossibleConstraints() {
        // Two motifs 200 residues apart in a 300-residue protein, with the
        // ordered region between them: any construct keeping both is fine, so
        // make it impossible instead by requiring a motif inside the disordered
        // tail of a protein whose ordered part is too short.
        var disordered = [Bool](repeating: true, count: 100)
        for index in 40..<70 { disordered[index] = false }
        let constraints = [
            ConstructConstraint(kind: .motif, range: 45...50, label: "one")
        ]
        let result = ConstructSolver.propose(
            residueCount: 100, disordered: disordered, constraints: constraints)
        // 30% ordered clears the floor, so this must produce something: what it
        // must not do is cut the motif.
        for proposal in result.proposals {
            #expect(proposal.range.lowerBound <= 45 && proposal.range.upperBound >= 50)
        }
    }

    @Test("Proposals are ranked and distinct")
    func rankingIsStable() {
        let (disordered, constraints) = standard()
        let result = ConstructSolver.propose(
            residueCount: 300, disordered: disordered, constraints: constraints,
            limit: 5)
        let proposals = result.proposals
        #expect(proposals.count > 1)
        #expect(Set(proposals.map(\.id)).count == proposals.count)
        #expect(zip(proposals, proposals.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(proposals.allSatisfy { $0.length >= ConstructSolver.minimumLength })
    }
}
