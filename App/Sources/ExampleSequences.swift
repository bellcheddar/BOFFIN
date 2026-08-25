//  ExampleSequences.swift
//  BOFFIN
//
//  The two sequences the app can load without the user finding one first.
//
//  These lived inside `SequenceInputView` as private constants, which meant the
//  only way to reach them was to open the input sheet and then press a second
//  button. An empty state that says "load a sequence" while holding two
//  perfectly good ones is a screen that knows what you need and will not do it,
//  so they moved out here where every empty state can offer them directly.

import Foundation

enum ExampleSequences {
    struct Example: Identifiable, Hashable {
        let id: String
        /// What the button says.
        let title: String
        /// Why this one is here, for the onboarding sheet.
        let reason: String
        let fasta: String
    }

    /// Ubiquitin: small, fast, and the honest "no family" answer.
    ///
    /// The same 76 residues as the 1UBQ fixture the tests use, so what a first
    /// run shows is what the test suite asserts about.
    static let ubiquitin = Example(
        id: "1UBQ",
        title: "Ubiquitin",
        reason: "76 residues, folded end to end, and no family the classifier knows.",
        fasta: ">1UBQ ubiquitin\n"
            + "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG")

    /// Human CDK2: the protein every KLIFS number in this app was checked
    /// against, so the Family tab has something to recognise.
    static let cdk2 = Example(
        id: "P24941",
        title: "CDK2 kinase",
        reason: "A kinase, so pocket numbering, motifs and the classifier all have work to do.",
        fasta: ">sp|P24941|CDK2_HUMAN cyclin-dependent kinase 2\n"
            + "MENFQKVEKIGEGTYGVVYKARNKLTGEVVALKKIRLDTETEGVPSTAIREISLLKELNH"
            + "PNIVKLLDVIHTENKLYLVFEFLHQDLKKFMDASALTGIPLPLIKSYLFQLLQGLAFCHS"
            + "HRVLHRDLKPQNLLINTEGAIKLADFGLARAFGVPVRTYTHEVVTLWYRAPEILLGCKYY"
            + "STAVDIWSLGCIFAEMVTRRALFPGDSEIDQLFRIFRTLGTPDEVVWPGVTSMPDYKPSF"
            + "PKWARQDFSKVVPPLDEDGRSLLSQMLHYDPNKRISAKAALAHPFFQDVTKPVPHLRL")

    static let all: [Example] = [ubiquitin, cdk2]
}
