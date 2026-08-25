//  BoffinIntents.swift
//  BOFFIN
//
//  Phase 10: Shortcuts and Siri.
//
//  An App Intent is a promise that the work happens without the interface, so
//  everything here calls into the packages directly rather than driving the app.
//  An intent that opens a tab and waits for a view to appear is not an intent,
//  it is a launcher.
//
//  Only the analysis that needs no model is exposed. A Shortcut that sometimes
//  returns properties and sometimes fails because a 67 MB asset has not been
//  downloaded is worse than one that never offered the option: automation is
//  judged on whether it can be relied upon, not on its best case.

import AppIntents
import BoffinCore
import Foundation

/// Compute the analytical properties of a sequence.
struct AnalyseSequenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyse a protein sequence"
    static let description = IntentDescription(
        "Molecular weight, isoelectric point, extinction coefficient, GRAVY and the instability index, computed on device. No network and no model needed.",
        categoryName: "Analysis")

    /// Runs without bringing the app forward: the point is the numbers.
    static let openAppWhenRun = false

    @Parameter(title: "Sequence", description: "One-letter codes, or a FASTA record.")
    var sequence: String

    // Both scales are offered rather than one being chosen, for the same reason
    // the app offers both: they disagree by 0.2 to 0.5 pH units and which is
    // right depends on what the answer is being compared against.
    @Parameter(title: "pKa scale", default: .bjellqvist)
    var scale: PKaScaleChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Analyse \(\.$sequence) using the \(\.$scale) scale")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let parsed = try FASTAParser.parse(sequence)
        guard let protein = parsed.sequences.first else {
            throw AnalysisError.noSequence
        }
        let properties = SequenceProperties(protein, pKaScale: scale.value)

        // The scale travels with the numbers. A Shortcut's output is pasted
        // into things, and an isoelectric point with no scale beside it is a
        // number nobody can reproduce.
        let report = """
            \(protein.count) residues
            Molecular weight  \(String(format: "%.1f", properties.molecularWeight)) Da
            Isoelectric point \(String(format: "%.2f", properties.isoelectricPoint)) \
            (\(scale.value.provenance))
            Extinction 280 nm \(String(format: "%.0f", properties.extinctionCoefficientReduced)) \
            reduced, \(String(format: "%.0f", properties.extinctionCoefficientCystine)) with cystines
            GRAVY             \(String(format: "%.3f", properties.gravy))
            Instability index \(String(format: "%.2f", properties.instabilityIndex))
            """
        return .result(value: report, dialog: IntentDialog(stringLiteral: report))
    }

    enum AnalysisError: Error, CustomLocalizedStringResourceConvertible {
        case noSequence

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noSequence: "No sequence was found in that text."
            }
        }
    }
}

/// The pKa scale, as a Shortcuts-visible choice.
///
/// Both are offered rather than one being chosen, for the same reason the app
/// offers both: they disagree by 0.2 to 0.5 pH units and which one is right
/// depends on what the answer is being compared against.
enum PKaScaleChoice: String, AppEnum {
    case bjellqvist
    case emboss

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "pKa scale")
    static let caseDisplayRepresentations: [PKaScaleChoice: DisplayRepresentation] = [
        .bjellqvist: "Bjellqvist (ExPASy ProtParam)",
        .emboss: "EMBOSS",
    ]

    var value: PKaScale {
        switch self {
        case .bjellqvist: .bjellqvist
        case .emboss: .emboss
        }
    }
}

/// Find the canonical motifs in a sequence.
struct FindMotifsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find kinase or GPCR motifs"
    static let description = IntentDescription(
        "Detects protein kinase and class A GPCR sequence motifs, with the ordering constraints that make a pattern match evidence. On device, no model needed.",
        categoryName: "Analysis")
    static let openAppWhenRun = false

    @Parameter(title: "Sequence")
    var sequence: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let parsed = try FASTAParser.parse(sequence)
        guard let protein = parsed.sequences.first else {
            throw AnalyseSequenceIntent.AnalysisError.noSequence
        }
        let found = FamilyMotifs.all(in: protein)
        guard !found.isEmpty else {
            // Not an error, and not an empty string: finding nothing is an
            // answer, and a Shortcut that returns "" reads as a failure.
            return .result(
                value: "No protein kinase or class A GPCR motifs were found. That is "
                    + "not a statement that the protein belongs to neither: it means "
                    + "the anchors BOFFIN looks for were not present in the expected "
                    + "order.")
        }
        let lines = found.flatMap { family, motifs in
            motifs.map { motif in
                "\(motif.name) \(motif.matched) at \(motif.range.lowerBound + 1)"
            }
        }
        return .result(value: lines.sorted().joined(separator: "\n"))
    }
}

struct BoffinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnalyseSequenceIntent(),
            phrases: [
                "Analyse a sequence with \(.applicationName)",
                "Sequence properties in \(.applicationName)",
            ],
            shortTitle: "Analyse sequence",
            systemImageName: "waveform.path.ecg")
        AppShortcut(
            intent: FindMotifsIntent(),
            phrases: ["Find motifs with \(.applicationName)"],
            shortTitle: "Find motifs",
            systemImageName: "point.3.connected.trianglepath.dotted")
    }
}
