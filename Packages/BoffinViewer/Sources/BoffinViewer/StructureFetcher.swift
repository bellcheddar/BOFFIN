//  StructureFetcher.swift
//  BoffinViewer
//
//  Fetching structures from RCSB and AlphaFold DB.
//
//  Additive, and it degrades cleanly. Hard rule 2 is that the app works fully
//  offline, so nothing here is on a core path: the bundled fixtures load without
//  it, and a failure is an ordinary state with a reason in it rather than a
//  blocked screen.
//
//  A predicted model is NOT a structure
//  ------------------------------------
//  AlphaFold entries are labelled as predictions everywhere they appear, and the
//  type makes that impossible to lose: `Source` travels with the data, and the
//  confidence column of a predicted model is pLDDT rather than a B-factor, which
//  is the same number in the same field meaning something entirely different.
//  Colouring one as the other produces a picture that is beautiful and wrong.

import Foundation

/// Where a structure came from, and what its confidence column means.
public enum StructureSource: Sendable, Hashable {
    case bundled(String)
    case experimental(pdbID: String)
    case predicted(accession: String)

    public var isPrediction: Bool {
        if case .predicted = self { return true }
        return false
    }

    /// What the per-atom confidence column holds.
    public var confidenceLabel: String {
        switch self {
        case .predicted: "pLDDT (0 to 100, higher is more confident)"
        case .experimental, .bundled: "B-factor (angstroms squared, lower is better ordered)"
        }
    }

    public var caveat: String? {
        switch self {
        case .predicted:
            "This is a PREDICTED model, not an experimental structure. Its confidence "
                + "column is pLDDT, and regions below 70 are commonly disordered rather "
                + "than badly predicted."
        case .experimental, .bundled:
            nil
        }
    }
}

/// A fetched structure and where it came from.
public struct FetchedStructure: Sendable {
    public let data: Data
    public let format: LoadStructureCommand.StructureFormat
    public let source: StructureSource
}

public enum StructureFetchError: Error, Sendable {
    case notFound(String)
    case network(String)
    case tooLarge(bytes: Int)
}

public struct StructureFetcher: Sendable {

    /// Refuse anything larger than this rather than filling memory on a phone.
    ///
    /// 60 MB of BinaryCIF is a very large assembly indeed; the ribosome fixture
    /// is 7.7 MB. The limit exists so that a mistyped accession pointing at
    /// something enormous fails quickly and legibly.
    public static let maximumBytes = 60 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch an experimental structure from RCSB as BinaryCIF.
    ///
    /// BinaryCIF rather than mmCIF: markedly smaller over a mobile connection
    /// and there is no text to tokenise at the other end.
    public func rcsb(_ pdbID: String) async throws -> FetchedStructure {
        let identifier = pdbID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard identifier.count == 4, identifier.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            throw StructureFetchError.notFound("\(pdbID) is not a PDB identifier")
        }
        guard let url = URL(string: "https://models.rcsb.org/\(identifier).bcif") else {
            throw StructureFetchError.notFound("\(pdbID) does not form a URL")
        }
        let data = try await fetch(url, describedAs: identifier.uppercased())
        return FetchedStructure(
            data: data, format: .binaryCIF,
            source: .experimental(pdbID: identifier.uppercased()))
    }

    /// Fetch a predicted model from AlphaFold DB by UniProt accession.
    public func alphaFold(_ accession: String) async throws -> FetchedStructure {
        let identifier = accession.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            throw StructureFetchError.notFound("\(accession) is not a UniProt accession")
        }
        // Version 4 is the current public release. Pinned rather than "latest",
        // because a silently changing model is a silently changing figure.
        guard
            let url = URL(
                string: "https://alphafold.ebi.ac.uk/files/AF-\(identifier)-F1-model_v4.cif")
        else {
            throw StructureFetchError.notFound("\(accession) does not form a URL")
        }
        let data = try await fetch(url, describedAs: identifier)
        return FetchedStructure(
            data: data, format: .mmCIF, source: .predicted(accession: identifier))
    }

    private func fetch(_ url: URL, describedAs name: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw StructureFetchError.notFound(
                    "\(name) returned HTTP \(http.statusCode)")
            }
            guard data.count <= Self.maximumBytes else {
                throw StructureFetchError.tooLarge(bytes: data.count)
            }
            return data
        } catch let error as StructureFetchError {
            throw error
        } catch {
            throw StructureFetchError.network(error.localizedDescription)
        }
    }
}
