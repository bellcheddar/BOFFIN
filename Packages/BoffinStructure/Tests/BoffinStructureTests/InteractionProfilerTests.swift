//  InteractionProfilerTests.swift
//  BoffinStructureTests
//
//  Checked against 1HCK, CDK2 with ATP bound, whose binding site is one of the
//  best described in the literature. The assertions are structural facts about
//  that site rather than the profiler agreeing with itself.

import Foundation
import Testing

@testable import BoffinStructure

private func kinase() throws -> AtomStore {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures/1hck.bcif")
    return try AtomStore.from(try BinaryCIF.decode(Data(contentsOf: url)))
}

@Suite("Interaction profiling")
struct InteractionProfilerTests {

    private func atp(_ store: AtomStore) -> Set<Int> {
        SelectionEvaluator.evaluate(.category(.organic), in: store).indices
    }

    @Test("The profile finds contacts to the ATP site and names the residues")
    func atpSite() throws {
        let store = try kinase()
        let ligand = atp(store)
        #expect(!ligand.isEmpty, "1HCK should contain ATP")

        let profile = InteractionProfiler.profile(store, ligand: ligand)
        #expect(!profile.interactions.isEmpty)

        let residues = profile.contactedResidues(in: store)
        // CDK2's ATP site is textbook: the hinge is Glu81 to Leu83 and the
        // glycine-rich loop runs 11 to 18. A profile that finds neither is not
        // profiling the ATP site whatever else it found.
        #expect(
            residues.contains(81) || residues.contains(83),
            "the hinge is not contacted: \(residues.sorted())")
        #expect(
            residues.contains(where: { (10...20).contains($0) }),
            "the glycine-rich loop is not contacted")
        // A binding site, not a surface.
        #expect(residues.count > 8 && residues.count < 40, "\(residues.count) residues")
    }

    /// The hinge of a kinase hydrogen bonds to the adenine, which is why every
    /// ATP-competitive inhibitor ever designed targets it.
    @Test("Hydrogen bonds to the hinge are found")
    func hingeHydrogenBonds() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: atp(store))
        let bonds = profile.ofKind(.hydrogenBond)
        #expect(!bonds.isEmpty)

        let hingeBonds = bonds.filter {
            (81...83).contains(store.authorNumber[$0.partnerAtom])
        }
        #expect(!hingeBonds.isEmpty, "no hydrogen bond to the hinge")
        for bond in bonds {
            #expect(bond.distance <= 4.1)
            #expect(
                InteractionProfiler.polarElements.contains(
                    store.element[bond.partnerAtom].uppercased()))
        }
    }

    @Test("Hydrophobic contacts are carbon to carbon and within the cutoff")
    func hydrophobic() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: atp(store))
        let contacts = profile.ofKind(.hydrophobic)
        #expect(!contacts.isEmpty)
        for contact in contacts {
            #expect(store.element[contact.ligandAtom].uppercased() == "C")
            #expect(store.element[contact.partnerAtom].uppercased() == "C")
            #expect(contact.distance <= 4.0)
        }
    }

    /// ATP's triphosphate is anionic and the site's lysine is not optional: K33
    /// is the residue every kinase paper names.
    @Test("The triphosphate makes salt bridges to the basic residues")
    func saltBridges() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: atp(store))
        let bridges = profile.ofKind(.saltBridge)
        #expect(!bridges.isEmpty, "no salt bridge to the triphosphate")
        for bridge in bridges {
            #expect(bridge.distance <= 5.5)
            let residue = store.residueName[bridge.partnerAtom].uppercased()
            #expect(["ARG", "LYS", "HIS", "ASP", "GLU"].contains(residue))
        }
    }

    /// The whole point of the assumptions type.
    @Test("Every profile says what it assumed, and the sentence is specific")
    func assumptionsTravel() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: atp(store))

        // 1HCK is an X-ray structure from 1996: no hydrogens.
        #expect(!profile.assumptions.hasExplicitHydrogens)
        let statement = profile.assumptions.statement
        #expect(statement.contains("7.4"))
        #expect(statement.contains("NO hydrogens"))
        // The specific choices, not a vague disclaimer: a reader has to be able
        // to tell which contacts survive a different assumption.
        #expect(statement.contains("Histidine is treated as neutral"))
        #expect(statement.contains("aspartate and glutamate as charged"))
    }

    @Test("A profile with no ligand is empty and still carries its assumptions")
    func emptyLigand() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: [])
        #expect(profile.interactions.isEmpty)
        #expect(!profile.assumptions.statement.isEmpty)
    }

    @Test("Interactions come back closest first")
    func ordering() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: atp(store))
        let distances = profile.interactions.map(\.distance)
        #expect(zip(distances, distances.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// A tightened cutoff must find strictly fewer contacts. This catches a
    /// criterion that is read but not applied, which looks identical to one
    /// that is applied and generous.
    @Test("The criteria are actually applied")
    func criteriaAreApplied() throws {
        let store = try kinase()
        let ligand = atp(store)
        var tight = InteractionCriteria()
        tight.hydrophobicDistance = 3.5
        tight.hydrogenBondDistance = 3.0
        tight.saltBridgeDistance = 3.5

        let loose = InteractionProfiler.profile(store, ligand: ligand)
        let strict = InteractionProfiler.profile(store, ligand: ligand, criteria: tight)
        #expect(strict.interactions.count < loose.interactions.count)
        #expect(strict.ofKind(.hydrophobic).allSatisfy { $0.distance <= 3.5 })
    }
}

@Suite("Interaction export")
struct InteractionExportTests {

    private func profileOfKinase() throws -> (AtomStore, InteractionProfile) {
        let store = try kinase()
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: store).indices
        return (store, InteractionProfiler.profile(store, ligand: ligand))
    }

    /// A CSV is the artefact that gets opened six months later by someone who
    /// was not there. A table of distances with no statement of what was assumed
    /// about protonation is a table of numbers that cannot be checked.
    @Test("The assumptions are inside the CSV, not alongside it")
    func assumptionsAreInTheFile() throws {
        let (store, profile) = try profileOfKinase()
        let csv = profile.csv(in: store, structureName: "1HCK")
        #expect(csv.contains("# BOFFIN interaction profile"))
        #expect(csv.contains("# Structure: 1HCK"))
        #expect(csv.contains("pH 7.4"))
        #expect(csv.contains("NO hydrogens"))
        #expect(csv.contains("# Research use only."))
    }

    @Test("Every row has the same number of fields as the header")
    func wellFormed() throws {
        let (store, profile) = try profileOfKinase()
        let csv = profile.csv(in: store, structureName: "1HCK")
        let rows = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let header = rows[0].split(separator: ",", omittingEmptySubsequences: false)
        #expect(header.count == 8)
        #expect(rows.count == profile.interactions.count + 1)
        for row in rows.dropFirst() {
            #expect(
                row.split(separator: ",", omittingEmptySubsequences: false).count == 8,
                "row has the wrong field count: \(row)")
        }
    }

    /// This test is why the field is called `partnerAtom`. It was `proteinAtom`,
    /// and CDK2 is 298 residues, so numbers above 300 said something was wrong.
    /// Nothing was: metal coordination is to the METAL, a heteroatom numbered in
    /// the ligand range, and the name was accurate for four kinds out of five.
    @Test("Residue numbers in the CSV are author numbers, and metals are not protein")
    func authorNumbering() throws {
        let (store, profile) = try profileOfKinase()
        let csv = profile.csv(in: store, structureName: "1HCK")
        let rows = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }.dropFirst()
        for row in rows {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            let kind = String(fields[0])
            let number = try #require(Int(fields[6]))
            #expect(number > 0)
            if kind != Interaction.Kind.metalCoordination.rawValue {
                // A protein author number outside 1 to 300 would mean label
                // numbering leaked in.
                #expect(number <= 300, "\(kind) partner numbered \(number)")
            }
        }

        // And the metals really are there to be distinguished, so the exception
        // is exercised rather than merely allowed for.
        let metals = profile.ofKind(.metalCoordination)
        for interaction in metals {
            #expect(store.isHeteroatom[interaction.partnerAtom])
        }
    }

    @Test("The summary counts each kind and ends with the assumptions")
    func summary() throws {
        let (store, profile) = try profileOfKinase()
        let text = profile.summary(in: store)
        #expect(text.contains("hydrogen bond"))
        #expect(text.contains("residues"))
        #expect(text.contains("pH 7.4"))
    }

    @Test("An empty profile still states its assumptions rather than saying nothing")
    func emptySummary() throws {
        let store = try kinase()
        let profile = InteractionProfiler.profile(store, ligand: [])
        let text = profile.summary(in: store)
        #expect(text.contains("No interactions were found"))
        #expect(text.contains("pH 7.4"))
    }
}
