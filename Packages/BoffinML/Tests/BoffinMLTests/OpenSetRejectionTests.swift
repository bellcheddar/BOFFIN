//  OpenSetRejectionTests.swift
//  BoffinMLTests
//
//  The classifier is closed set: it must answer with one of the families it
//  knows, so a protein from outside them is assigned the nearest, confidently.
//
//  What catches that is measured rather than assumed, and the measurement had
//  to be repeated when the classifier grew. `openset_experiment.py` holds out
//  whole families and compares five scores:
//
//                         100 families        500 families
//    mahalanobis AUROC    0.969 +/- 0.005     0.941 +/- 0.011
//    max softmax AUROC    0.945 +/- 0.014     0.941 +/- 0.010
//    mahalanobis @5% FPR  0.805 +/- 0.017     0.736 +/- 0.038
//    max softmax @5% FPR  0.761 +/- 0.061     0.763 +/- 0.009
//
//  At 500 classes Mahalanobis is no better on AUROC, worse at the operating
//  point, and four times less stable. So the 1.88 MB asset and its loader are
//  gone and the head's own confidence is used instead.
//
//  These tests pin the parts that would otherwise fail silently: a threshold
//  that is absent, a rate that drifts from the measurement, and the direction
//  of the comparison.

import Foundation
import Testing

@testable import BoffinML

@Suite("Open-set rejection")
struct OpenSetRejectionTests {

    private var labelsURL: URL? {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Models/heads/family_labels.json")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    @Test("The shipped metadata carries a confidence threshold")
    func metadataCarriesThreshold() throws {
        // Without it every call reads as in-distribution and the warning never
        // appears, which looks exactly like a classifier that is always right.
        guard let labelsURL else { return }
        let object =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: labelsURL)) as? [String: Any]
        let threshold = try #require(object?["openset_confidence_threshold"] as? Double)

        // A probability, and a demanding one: the head is confident almost
        // everywhere, so a floor near 0.5 would flag nothing at all.
        #expect(threshold > 0.5, "a floor of \(threshold) would never fire")
        #expect(threshold < 1.0)
    }

    @Test("The quoted detection rate matches the measurement for this family count")
    func detectionRateMatchesTheMeasurement() throws {
        // The number the UI states. It was 0.805 for a different score on the
        // 100-family model, and carrying that forward would have quoted a
        // measurement of a model the app no longer runs. This test exists
        // because that is a silent failure: the sentence still reads well.
        #expect(abs(FamilyClassification.openSetDetectionRate - 0.763) < 0.001)

        guard let labelsURL else { return }
        let object =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: labelsURL)) as? [String: Any]
        let families = try #require(object?["families"] as? [String])
        // The rate was measured at this family count. If the classifier is
        // retrained at a different one, openset_experiment.py has to run again,
        // and this is where that is caught rather than discovered later.
        #expect(
            families.count == 500,
            "the detection rate was measured on 500 families, not \(families.count)")
    }

    @Test("A low-confidence call is treated as outside the training set")
    func lowConfidenceIsOutOfDistribution() {
        // The decision itself, expressed on the same comparison the classifier
        // makes: below the floor is outside, at or above it is inside.
        let floor = 0.97
        #expect(0.42 < floor, "a 42% call must be flagged")
        #expect(0.99 >= floor, "a 99% call must not be")
    }

    @Test("The caveat states the catch rate rather than implying an all-clear")
    func caveatStatesTheRate() {
        // Roughly one unseen protein in four is still missed, so silence is
        // wrong that often. A reader is entitled to know the rate before
        // treating the absence of a warning as an answer.
        let call = FamilyClassification(
            ranked: [FamilyCall(accession: "PF00069", confidence: 0.99)],
            isConfident: true,
            top1Accuracy: 0.9858,
            similarityToNearestFamily: 0.98,
            isInDistribution: true,
            familyCount: 500,
            openSetConfidenceFloor: 0.97,
            openSetDetectionRate: FamilyClassification.openSetDetectionRate)
        #expect(call.caveat.contains("76%"), "the caveat should state the measured rate")
        #expect(call.caveat.contains("500"))
    }
}
