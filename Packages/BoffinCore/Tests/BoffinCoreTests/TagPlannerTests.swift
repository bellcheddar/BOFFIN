//  TagPlannerTests.swift
//  BoffinCoreTests
//
//  The internal-site check is the part that earns its keep, so it is tested
//  first and hardest: a protease whose recognition sequence occurs inside the
//  construct must be REFUSED, not offered with a warning.

import Testing

@testable import BoffinCore

@Suite("Tag and protease planning")
struct TagPlannerTests {

    private func residues(_ text: String) -> [AminoAcid] {
        text.compactMap { AminoAcid(rawValue: $0) }
    }

    private var ordinary: [AminoAcid] {
        residues(String(repeating: "AGSTKRDNQ", count: 20))
    }

    @Test("A signal peptide forces the tag to the C terminus")
    func signalPeptideForcesCTerminus() {
        let plan = TagPlanner.plan(
            construct: ordinary, hasSignalPeptide: true,
            startsDisordered: true, endsDisordered: false)
        #expect(plan.terminus == .carboxyTerminal)
        #expect(plan.rationale.contains { $0.contains("signal peptide") })
    }

    @Test("The disordered terminus is preferred when only one is")
    func disorderedTerminusWins() {
        let amino = TagPlanner.plan(
            construct: ordinary, hasSignalPeptide: false,
            startsDisordered: true, endsDisordered: false)
        #expect(amino.terminus == .aminoTerminal)

        let carboxy = TagPlanner.plan(
            construct: ordinary, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: true)
        #expect(carboxy.terminus == .carboxyTerminal)
    }

    @Test("With nothing to choose between them, the default says it is a default")
    func defaultIsLabelledAsOne() {
        let plan = TagPlanner.plan(
            construct: ordinary, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)
        #expect(plan.terminus == .aminoTerminal)
        #expect(plan.rationale.contains { $0.contains("conventional default") })
    }

    /// The failure this exists to prevent: a TEV site inside the protein means
    /// TEV cuts the protein in half, and the result looks like proteolysis in
    /// the prep rather than a design error.
    @Test("A protease whose site occurs internally is refused, not ranked low")
    func refusesInternalSites() {
        let withTEV = residues("AGSTKRD" + "ENLYFQG" + "AGSTKRDNQAGSTKRDNQ")
        let plan = TagPlanner.plan(
            construct: withTEV, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)

        #expect(!plan.usableProteases.contains { $0.name == "TEV" })
        let refusal = plan.refusedProteases.first { $0.protease.name == "TEV" }
        #expect(refusal != nil)
        #expect(refusal?.position == 7)
        // The others are unaffected, so the check is per protease rather than
        // an all-or-nothing veto.
        #expect(plan.usableProteases.contains { $0.name == "HRV 3C" })
    }

    @Test("Each protease is checked independently")
    func checksEachProtease() {
        let both = residues("AAA" + "LEVLFQGP" + "AAA" + "LVPRGS" + "AAAAAA")
        let plan = TagPlanner.plan(
            construct: both, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)
        #expect(plan.refusedProteases.count == 2)
        #expect(plan.usableProteases.map(\.name) == ["TEV"])
    }

    @Test("A construct that defeats every protease says so")
    func allRefused() {
        let all = residues(
            "AAA" + "ENLYFQG" + "AAA" + "LEVLFQGP" + "AAA" + "LVPRGS" + "AAA")
        let plan = TagPlanner.plan(
            construct: all, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)
        #expect(plan.usableProteases.isEmpty)
        #expect(plan.refusedProteases.count == 3)
        #expect(plan.rationale.contains { $0.contains("the tag has to") })
    }

    @Test("A clean construct offers all three, most specific first")
    func cleanConstruct() {
        let plan = TagPlanner.plan(
            construct: ordinary, hasSignalPeptide: false,
            startsDisordered: false, endsDisordered: false)
        #expect(plan.usableProteases.count == 3)
        #expect(plan.usableProteases.map(\.name) == ["TEV", "HRV 3C", "Thrombin"])
        #expect(plan.refusedProteases.isEmpty)
        // Thrombin is last because it is the least specific, and the note says
        // so rather than leaving the ordering to be inferred.
        #expect(plan.usableProteases.last?.note.contains("least specific") == true)
    }

    @Test("Site search is exact, not a locale-aware string comparison")
    func searchIsExact() {
        #expect(TagPlanner.firstOccurrence(of: "ENLYFQG", in: "AAENLYFQGAA") == 2)
        #expect(TagPlanner.firstOccurrence(of: "ENLYFQG", in: "ENLYFQ") == nil)
        #expect(TagPlanner.firstOccurrence(of: "AA", in: "") == nil)
        #expect(TagPlanner.firstOccurrence(of: "", in: "AAA") == nil)
        // A near miss must not match: one residue different is a different site.
        #expect(TagPlanner.firstOccurrence(of: "ENLYFQG", in: "AAENLYFQSAA") == nil)
    }

    @Test("The recognition sequences are the published ones")
    func publishedSequences() {
        // Pinned because a typo here is invisible: the construct would be
        // designed with a site no protease recognises, and it would only show
        // up at the cleavage step, months later.
        #expect(Protease.tev.recognition == "ENLYFQG")
        #expect(Protease.tev.scar == "G")
        #expect(Protease.hrv3C.recognition == "LEVLFQGP")
        #expect(Protease.hrv3C.scar == "GP")
        #expect(Protease.thrombin.recognition == "LVPRGS")
        #expect(Protease.thrombin.scar == "GS")
    }
}
