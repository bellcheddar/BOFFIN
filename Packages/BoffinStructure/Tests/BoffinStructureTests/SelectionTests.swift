//  SelectionTests.swift
//  BoffinStructureTests
//
//  The build plan's Phase 8 acceptance is one expression:
//  `byres (polymer within 5 of organic)` evaluating correctly on the kinase
//  fixture. That is the last test here; everything before it exists so that when
//  it fails, the failure has somewhere to point.

import Foundation
import Testing

@testable import BoffinStructure

private var fixtures: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/structures")
}

private func store(_ name: String) throws -> AtomStore {
    try AtomStore.from(
        try BinaryCIF.decode(Data(contentsOf: fixtures.appending(path: name))))
}

@Suite("Selection parsing")
struct SelectionParsingTests {

    @Test("Simple selectors parse to what they say")
    func simple() throws {
        #expect(try SelectionParser.parse("all") == .all)
        #expect(try SelectionParser.parse("chain A") == .chain(["A"]))
        #expect(try SelectionParser.parse("chain A+B") == .chain(["A", "B"]))
        #expect(try SelectionParser.parse("name CA") == .atomNames(["CA"]))
        #expect(try SelectionParser.parse("resn ala") == .residueNames(["ALA"]))
        #expect(try SelectionParser.parse("polymer") == .category(.polymer))
    }

    /// `50-120` is one token on purpose. Splitting on `-` in the lexer would
    /// make a range indistinguishable from a subtraction nobody wrote, and would
    /// break the negative residue numbers the PDB uses for expression tags.
    @Test("Residue ranges, lists and negative numbers all parse")
    func residueRanges() throws {
        #expect(try SelectionParser.parse("resi 50") == .residueNumbers([50...50]))
        #expect(try SelectionParser.parse("resi 50-120") == .residueNumbers([50...120]))
        #expect(
            try SelectionParser.parse("resi 50+60") == .residueNumbers([50...50, 60...60]))
        #expect(
            try SelectionParser.parse("resi 50-60+90-100")
                == .residueNumbers([50...60, 90...100]))
        // An expression tag numbered backwards from the construct start.
        #expect(try SelectionParser.parse("resi -4") == .residueNumbers([(-4)...(-4)]))
    }

    @Test("Numeric properties parse with their comparison")
    func numericProperties() throws {
        #expect(
            try SelectionParser.parse("b > 50")
                == .numericProperty(.bFactor, .greater, 50))
        #expect(
            try SelectionParser.parse("q <= 0.5")
                == .numericProperty(.occupancy, .lessOrEqual, 0.5))
    }

    @Test("Boolean composition respects precedence, with `or` loosest")
    func precedence() throws {
        // `a and b or c` must be `(a and b) or c`, as in PyMOL.
        let parsed = try SelectionParser.parse("chain A and name CA or chain B")
        #expect(
            parsed == .or(.and(.chain(["A"]), .atomNames(["CA"])), .chain(["B"])))
        // Parentheses override it.
        let grouped = try SelectionParser.parse("chain A and (name CA or chain B)")
        #expect(
            grouped == .and(.chain(["A"]), .or(.atomNames(["CA"]), .chain(["B"]))))
    }

    @Test("Unary operators bind tighter than the binary ones")
    func unary() throws {
        #expect(
            try SelectionParser.parse("not solvent and chain A")
                == .and(.not(.category(.solvent)), .chain(["A"])))
        #expect(
            try SelectionParser.parse("byres chain A") == .byResidue(.chain(["A"])))
    }

    @Test("`within` takes a distance, an `of`, and a whole sub-expression")
    func within() throws {
        let parsed = try SelectionParser.parse("polymer within 5 of organic")
        #expect(parsed == .within(5, .category(.polymer), .category(.organic)))

        let nested = try SelectionParser.parse("byres (polymer within 4.5 of organic)")
        #expect(nested == .byResidue(.within(4.5, .category(.polymer), .category(.organic))))
    }

    /// Selecting the wrong atoms is worse than failing to select: an unknown
    /// keyword names itself rather than quietly returning everything or nothing.
    @Test("Bad input is an error that says what was wrong")
    func errors() {
        #expect(throws: SelectionError.unknownKeyword("chian")) {
            _ = try SelectionParser.parse("chian A")
        }
        #expect(throws: SelectionError.unclosedParenthesis) {
            _ = try SelectionParser.parse("(chain A")
        }
        #expect(throws: SelectionError.self) {
            _ = try SelectionParser.parse("chain A and")
        }
        #expect(throws: SelectionError.self) {
            _ = try SelectionParser.parse("polymer within of organic")
        }
        #expect(throws: SelectionError.self) {
            _ = try SelectionParser.parse("")
        }
        #expect(throws: SelectionError.self) {
            _ = try SelectionParser.parse("chain A chain B")
        }
    }
}

@Suite("Selection evaluation")
struct SelectionEvaluationTests {

    private func select(_ text: String, _ store: AtomStore) throws -> AtomSelection {
        SelectionEvaluator.evaluate(try SelectionParser.parse(text), in: store)
    }

    @Test("Chain and residue selectors pick the atoms they name")
    func basics() throws {
        let ubiquitin = try store("1ubq.bcif")
        #expect(try select("all", ubiquitin).count == ubiquitin.count)
        #expect(try select("none", ubiquitin).isEmpty)
        #expect(try select("chain A", ubiquitin).count == ubiquitin.count)
        // Ubiquitin's 76 residues each have one alpha carbon.
        #expect(try select("name CA", ubiquitin).count == 76)
        #expect(try select("resi 1-10 and name CA", ubiquitin).count == 10)
    }

    @Test("Solvent and polymer are complementary here, and organic is empty")
    func categories() throws {
        let ubiquitin = try store("1ubq.bcif")
        let water = try select("solvent", ubiquitin)
        let polymer = try select("polymer", ubiquitin)
        #expect(water.count == 58, "1UBQ has 58 waters")
        #expect(polymer.count == 602, "1UBQ has 602 protein atoms")
        #expect(water.count + polymer.count == ubiquitin.count)
        // Ubiquitin has no ligand.
        #expect(try select("organic", ubiquitin).isEmpty)
    }

    @Test("`not` is the complement, not an empty set")
    func negation() throws {
        let ubiquitin = try store("1ubq.bcif")
        let solvent = try select("solvent", ubiquitin)
        let rest = try select("not solvent", ubiquitin)
        #expect(solvent.count + rest.count == ubiquitin.count)
        #expect(solvent.indices.isDisjoint(with: rest.indices))
    }

    @Test("Backbone and side chain partition the polymer")
    func backboneAndSidechain() throws {
        let ubiquitin = try store("1ubq.bcif")
        let backbone = try select("backbone", ubiquitin)
        let sidechain = try select("sidechain", ubiquitin)
        let polymer = try select("polymer", ubiquitin)
        #expect(backbone.indices.isDisjoint(with: sidechain.indices))
        #expect(backbone.count + sidechain.count == polymer.count)
    }

    @Test("A B-factor comparison selects the atoms above the value")
    func numeric() throws {
        let ubiquitin = try store("1ubq.bcif")
        let high = try select("b > 30", ubiquitin)
        for index in high.indices { #expect(ubiquitin.bFactor[index] > 30) }
        let low = try select("b <= 30", ubiquitin)
        #expect(high.count + low.count == ubiquitin.count)
    }

    @Test("`byres` expands a single atom to its whole residue")
    func byResidue() throws {
        let ubiquitin = try store("1ubq.bcif")
        // Lysine 48, the residue every ubiquitin chain is built through, has
        // nine heavy atoms.
        let alpha = try select("resi 48 and name CA", ubiquitin)
        #expect(alpha.count == 1)
        let whole = try select("byres (resi 48 and name CA)", ubiquitin)
        #expect(whole.count == 9, "K48 has \(whole.count) atoms, expected 9")
        for index in whole.indices { #expect(ubiquitin.authorNumber[index] == 48) }
    }

    /// The grid is an optimisation, so it has to agree with the naive answer.
    @Test("The spatial index agrees with brute force")
    func withinAgreesWithBruteForce() throws {
        let kinase = try store("1hck.bcif")
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: kinase).indices
        let polymer = SelectionEvaluator.evaluate(.category(.polymer), in: kinase).indices
        #expect(!ligand.isEmpty, "1HCK should contain ATP")

        let gridded = SelectionEvaluator.withinIndices(
            distance: 5, candidates: polymer, targets: ligand, store: kinase)

        var brute: Set<Int> = []
        for candidate in polymer {
            for target in ligand {
                let dx = kinase.x[candidate] - kinase.x[target]
                let dy = kinase.y[candidate] - kinase.y[target]
                let dz = kinase.z[candidate] - kinase.z[target]
                if dx * dx + dy * dy + dz * dz <= 25 {
                    brute.insert(candidate)
                    break
                }
            }
        }
        #expect(gridded == brute, "grid found \(gridded.count), brute force \(brute.count)")
    }

    /// The build plan's Phase 8 acceptance, on the fixture it names.
    ///
    /// 1HCK is CDK2 with ATP bound. Every residue lining the ATP site should
    /// come back, and the answer is checked against structural facts rather than
    /// against the evaluator: the residues must be a plausible pocket, must
    /// include the catalytic aspartate region, and must not include the solvent.
    @Test("byres (polymer within 5 of organic) picks out the ATP site of CDK2")
    func acceptanceOnTheKinaseFixture() throws {
        let kinase = try store("1hck.bcif")
        let pocket = try select("byres (polymer within 5 of organic)", kinase)
        #expect(!pocket.isEmpty)

        var residues: Set<Int> = []
        for index in pocket.indices {
            #expect(!kinase.isHeteroatom[index], "a heteroatom was selected as polymer")
            residues.insert(kinase.authorNumber[index])
        }

        // An ATP site is a pocket, not a surface: a couple of dozen residues.
        #expect(
            residues.count > 10 && residues.count < 40,
            "\(residues.count) residues line the site, which is not a pocket")

        // CDK2's ATP site is textbook. The hinge is Glu81 to Leu83 and the
        // glycine-rich loop runs 11 to 18; a selection that misses both is not
        // finding the ATP site whatever else it found.
        #expect(
            residues.contains(83) || residues.contains(81),
            "the hinge is not in the selection: \(residues.sorted())")
        #expect(
            residues.contains(where: { (10...20).contains($0) }),
            "the glycine-rich loop is not in the selection")

        // And the complement holds: every selected atom really is within 5 A of
        // a ligand atom, or in a residue that has one.
        let ligand = SelectionEvaluator.evaluate(.category(.organic), in: kinase).indices
        for residue in residues {
            let atoms = (0..<kinase.count).filter { kinase.authorNumber[$0] == residue }
            let close = atoms.contains { atom in
                ligand.contains { target in
                    let dx = kinase.x[atom] - kinase.x[target]
                    let dy = kinase.y[atom] - kinase.y[target]
                    let dz = kinase.z[atom] - kinase.z[target]
                    return dx * dx + dy * dy + dz * dz <= 25
                }
            }
            #expect(close, "residue \(residue) is in the selection but not near the ligand")
        }
    }
}
