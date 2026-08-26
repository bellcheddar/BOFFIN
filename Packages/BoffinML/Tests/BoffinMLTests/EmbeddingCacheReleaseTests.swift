import BoffinCore
import Foundation
import Testing

@testable import BoffinML

private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

private var modelsPresent: Bool {
    FileManager.default.fileExists(
        atPath: repoRoot.appending(path: "Models/esm2_t12_35M_UR50D.mlpackage").path)
}

@Suite("Embedding cache under pressure")
struct EmbeddingCacheReleaseTests {

    /// The cache is only worth releasing if it is really being kept, which it
    /// was not while the app built a new engine for every analysis.
    @Test("A repeated sequence is served from the cache", .enabled(if: modelsPresent))
    func cacheIsUsed() async throws {
        let engine = try EmbeddingEngine(
            modelURL: repoRoot.appending(path: "Models/esm2_t12_35M_UR50D.mlpackage"),
            tokeniserURL: repoRoot.appending(
                path: "Models/esm2_t12_35M_UR50D.tokeniser.json"))
        let sequence = ProteinSequence(
            name: "ubiquitin", letters: "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEG",
            source: .pasted)

        _ = try await engine.embed(sequence)
        #expect(await engine.cachedCount == 1)

        _ = try await engine.embed(sequence)
        #expect(await engine.cachedCount == 1, "a repeat must not add an entry")

        await engine.releaseUnderMemoryPressure()
        #expect(await engine.cachedCount == 0)
    }
}
