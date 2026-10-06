import Foundation
import ProviderCoreFoundation
import Testing

struct ServingPromptCountArtifactTests {
    @Test func countReceiptCannotRelabelDifferentOrChangedWeights() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let weight = directory.appendingPathComponent("model.safetensors")
        try Data("first exact artifact".utf8).write(to: weight)
        let expected = try #require(WeightHasher.computeHash(snapshotDir: directory))
        #expect(try ServingPromptCountQualificationTests.verifiedArtifactHash(
            directory: directory, modelID: "fixture", expected: expected) == expected)
        #expect(throws: (any Error).self) {
            try ServingPromptCountQualificationTests.verifiedArtifactHash(
                directory: directory, modelID: "fixture", expected: String(repeating: "0", count: 64))
        }
        try Data("replacement artifact".utf8).write(to: weight)
        #expect(throws: (any Error).self) {
            try ServingPromptCountQualificationTests.verifiedArtifactHash(
                directory: directory, modelID: "fixture", expected: expected)
        }
    }
}
