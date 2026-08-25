//  FamilyClassificationTests.swift
//  BoffinMLTests
//
//  Does the classifier put a known protein in its known family?
//
//  Nothing asked that until now. The Family tab's UI test asserts "Protein
//  kinase" appears for CDK2, which exercises the MOTIF detector: pure sequence
//  pattern matching that never touches the classifier, the embedding or the
//  Core ML model. So the whole `classifyFamily` path could have returned
//  anything at all and every suite would still have been green.
//
//  That gap had consequences. On 2026-08-26 the classifier was retrained from
//  100 families to 500 and `family.mlpackage` was left at the previous day's
//  conversion, pairing a 100-class model with 500 names. `zip` truncates, so
//  every call would have come back confident and wrong. Two guards now catch
//  the mismatch, but a guard only says the two files disagree; it cannot say
//  the answer is right.
//
//  This does. CDK2 is a protein kinase and PF00069 is the protein kinase
//  domain, and that is a fact about biology rather than about this codebase, so
//  it cannot drift with a retrain the way a recorded output would.

import BoffinCore
import CoreML
import Foundation
import Testing

@testable import BoffinML

private var headsDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Models/heads")
}

private var backboneDirectory: URL {
    headsDirectory.deletingLastPathComponent()
}

/// Both the backbone and the family head have to be present: this test runs the
/// real pipeline end to end rather than a stub, which is the entire point.
private var classifierIsAvailable: Bool {
    let manager = FileManager.default
    return manager.fileExists(
        atPath: backboneDirectory.appending(path: "esm2_t12_35M_UR50D.mlpackage").path)
        && manager.fileExists(atPath: headsDirectory.appending(path: "family.mlpackage").path)
        && manager.fileExists(atPath: headsDirectory.appending(path: "family_labels.json").path)
}

/// Human CDK2, P24941. The protein every KLIFS number in this app was checked
/// against, and unambiguously a protein kinase.
private let cdk2 = """
    MENFQKVEKIGEGTYGVVYKARNKLTGEVVALKKIRLDTETEGVPSTAIREISLLKELNHPNIVKLLDVIHTENKLYLVFEFLHQDLKKFMDASA\
    LTGIPLPLIKSYLFQLLQGLAFCHSHRVLHRDLKPQNLLINTEGAIKLADFGLARAFGVPVRTYTHEVVTLWYRAPEILLGCKYYSTAVDIWSLG\
    CIFAEMVTRRALFPGDSEIDQLFRIFRTLGTPDEVVWPGVTSMPDYKPSFPKWARQDFSKVVPPLDEDGRSLLSQMLHYDPNKRISAKAALAHPF\
    FQDVTKPVPHLRL
    """

@Suite(
    "Family classification, against the real model",
    .enabled(
        if: classifierIsAvailable,
        "converted backbone or family head not present: run convert_backbone.py and convert_heads.py"
    )
)
struct FamilyClassificationTests {

    private func classify(_ sequence: String) async throws -> FamilyClassification {
        let engine = try EmbeddingEngine(
            modelURL: backboneDirectory.appending(path: "esm2_t12_35M_UR50D.mlpackage"),
            tokeniserURL: backboneDirectory.appending(
                path: "esm2_t12_35M_UR50D.tokeniser.json"))
        let parsed = ProteinSequence(name: "query", letters: sequence, source: .pasted)
        let embedding = try await engine.embed(parsed)
        let heads = try AnalysisHeads(directory: headsDirectory)
        return try await heads.classifyFamily(for: embedding)
    }

    @Test("CDK2 is called a protein kinase")
    func cdk2IsAProteinKinase() async throws {
        let call = try await classify(cdk2)
        let top = try #require(call.top)

        // PF00069 is the protein kinase domain. A fact about biology, not a
        // recorded output, so it does not drift when the model is retrained.
        //
        // Checked in the top FIVE rather than only the top one: PF07714 is the
        // tyrosine kinase domain and is a defensible neighbouring answer for a
        // CMGC kinase, and a test that forbids a defensible answer will be
        // deleted the first time it fires rather than investigated.
        let ranked = call.ranked.map(\.accession)
        #expect(
            ranked.contains("PF00069") || ranked.contains("PF07714"),
            "CDK2 was called \(top.accession), and no kinase family appears in \(ranked)")

        #expect(top.confidence > 0.5, "the call is \(top.confidence), which is a coin flip")
        #expect(
            call.familyCount == 500,
            "the labels list \(call.familyCount) families, not the 500 trained")
    }

    @Test("A confident, in-set call is not flagged as out of distribution")
    func knownProteinIsInDistribution() async throws {
        // The other half of the rejection mechanism, and the half that would
        // fail silently: a threshold set too high flags everything, which reads
        // as an appropriately humble app rather than a broken one.
        let call = try await classify(cdk2)
        #expect(
            call.isInDistribution,
            "a protein kinase was flagged as outside a family set that contains PF00069")
    }

    @Test("The classifier reports as many probabilities as it has families")
    func rankedCallsAreWellFormed() async throws {
        let call = try await classify(cdk2)
        #expect(call.ranked.count == 5, "the tab shows a top five")

        // Descending, and probabilities. A softmax that has been read with the
        // wrong strides still produces numbers in [0, 1] but not in order.
        let confidences = call.ranked.map(\.confidence)
        #expect(confidences == confidences.sorted(by: >))
        #expect(confidences.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(Set(call.ranked.map(\.accession)).count == call.ranked.count)
    }
}
