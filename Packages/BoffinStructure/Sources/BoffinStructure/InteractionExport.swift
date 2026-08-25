//  InteractionExport.swift
//  BoffinStructure
//
//  A profile as text: CSV for a spreadsheet, and a summary for a figure legend.
//
//  The assumptions travel with the data, in the file, as a comment block. A CSV
//  is the artefact that gets opened six months later by someone who was not
//  there, and a table of distances with no statement of what was assumed about
//  protonation is a table of numbers that cannot be checked.

import Foundation

extension InteractionProfile {

    /// The profile as CSV, with the assumptions in a leading comment block.
    ///
    /// Comment lines start with `#`, which every spreadsheet and every parser
    /// worth using will either skip or show harmlessly in the first column.
    /// Losing the assumptions to make the file tidier would be tidying away the
    /// only thing that makes the numbers interpretable.
    public func csv(in store: AtomStore, structureName: String) -> String {
        var lines: [String] = []
        lines.append("# BOFFIN interaction profile")
        lines.append("# Structure: \(structureName)")
        for sentence in assumptions.statement.split(separator: ". ") {
            let text = sentence.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append("# \(text)\(text.hasSuffix(".") ? "" : ".")")
            }
        }
        lines.append("# Research use only.")
        lines.append(
            "type,distance_angstrom,ligand_atom,ligand_residue,partner_chain,"
                + "partner_residue,partner_number,partner_atom")

        for interaction in interactions {
            let ligand = interaction.ligandAtom
            let protein = interaction.partnerAtom
            lines.append(
                [
                    interaction.kind.rawValue,
                    String(format: "%.2f", interaction.distance),
                    escape(store.atomName[ligand]),
                    escape(store.residueName[ligand]),
                    escape(store.chainID[protein]),
                    escape(store.residueName[protein]),
                    String(store.authorNumber[protein]),
                    escape(store.atomName[protein]),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A one-paragraph summary for a figure legend or a message.
    public func summary(in store: AtomStore) -> String {
        guard !interactions.isEmpty else {
            return "No interactions were found within the criteria. "
                + assumptions.statement
        }
        var counts: [Interaction.Kind: Int] = [:]
        for interaction in interactions { counts[interaction.kind, default: 0] += 1 }

        let described = Interaction.Kind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(kind.name.lowercased())\(count == 1 ? "" : "s")"
        }
        let residues = contactedResidues(in: store).sorted()
        return
            "\(described.joined(separator: ", ")) across \(residues.count) residues "
            + "(\(residues.map(String.init).joined(separator: ", "))). "
            + assumptions.statement
    }

    /// Quote a CSV field only when it needs it.
    private func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
