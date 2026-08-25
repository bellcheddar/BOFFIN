//  OpenSetModelTests.swift
//  BoffinMLTests
//
//  The open-set distance has to agree with the Python that produced the
//  threshold. A Swift implementation that is self-consistently wrong would
//  compare its own numbers against a threshold computed from different ones,
//  and the result would be a rejection rate that is confidently meaningless.
//
//  This is the same shape of test as the tokeniser parity check, and for the
//  same reason: the failure it guards is silent.

import Foundation
import Testing

@testable import BoffinML

@Suite("Open-set rejection")
struct OpenSetModelTests {

    private struct Reference: Decodable {
        let queries: [[Float]]
        let expected: [Double]
    }

    private func reference() throws -> Reference {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures_maha_reference", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private var modelURL: URL? {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Models/heads/family_openset.bin")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    @Test("The Swift distance matches the Python that set the threshold")
    func matchesPython() throws {
        // Skipped rather than failed where the asset is not built: it is a
        // build artefact and CI has no copy. `try #require` on a missing file
        // would mark this FAILED, which is the mistake that turned CI red for
        // four commits earlier in this project.
        guard let modelURL else { return }
        let model = try #require(OpenSetModel(contentsOf: modelURL))
        let reference = try reference()

        for (query, expected) in zip(reference.queries, reference.expected) {
            let measured = try #require(model.distance(from: query))
            // Relative tolerance: these are squared distances spanning 6 to 370,
            // so a fixed absolute tolerance would be meaninglessly loose at one
            // end and impossible at the other. Float32 storage of a 480x480
            // whitener is the dominant error term.
            let tolerance = max(expected * 0.02, 0.05)
            #expect(
                abs(measured - expected) < tolerance,
                "Swift \(measured) against Python \(expected)")
        }
    }

    @Test("An embedding of the wrong width returns nothing, not a number")
    func rejectsWrongWidth() throws {
        guard let modelURL else { return }
        let model = try #require(OpenSetModel(contentsOf: modelURL))
        // A distance is compared against a threshold, so a plausible wrong
        // number is worse than no number: it would silently reject or accept.
        #expect(model.distance(from: [Float](repeating: 0, count: 10)) == nil)
        #expect(model.distance(from: []) == nil)
    }

    @Test("A truncated or foreign file loads as nothing rather than as garbage")
    func rejectsBadFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "boffin-openset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Not our format at all.
        let foreign = directory.appending(path: "foreign.bin")
        try Data("this is not an open-set model".utf8).write(to: foreign)
        #expect(OpenSetModel(contentsOf: foreign) == nil)

        // Correct magic, header claiming more data than is present. A truncated
        // download once left this project with 7% of the PDB and no error at
        // all, so the header's claim is checked against the file's length
        // before anything is read.
        var truncated = Data("BOFOSET1".utf8)
        truncated.append(contentsOf: withUnsafeBytes(of: Int32(100).littleEndian) { Data($0) })
        truncated.append(contentsOf: withUnsafeBytes(of: Int32(480).littleEndian) { Data($0) })
        truncated.append(contentsOf: withUnsafeBytes(of: Float32(327)) { Data($0) })
        truncated.append(Data(repeating: 0, count: 64))
        let short = directory.appending(path: "short.bin")
        try truncated.write(to: short)
        #expect(OpenSetModel(contentsOf: short) == nil)

        // A file that does not exist.
        #expect(OpenSetModel(contentsOf: directory.appending(path: "absent.bin")) == nil)
    }

    @Test("The shipped threshold is the one the experiment measured")
    func thresholdIsTheMeasuredOne() throws {
        guard let modelURL else { return }
        let model = try #require(OpenSetModel(contentsOf: modelURL))
        // Not a round number and not a guess: the 95th percentile of training
        // distances, so about one known protein in twenty is flagged. If this
        // ever becomes 0 or something tidy, the trainer stopped writing it and
        // everything would read as in-distribution.
        #expect(model.threshold > 1, "a threshold of \(model.threshold) rejects nothing")
        #expect(model.threshold < 100_000)
    }
}
