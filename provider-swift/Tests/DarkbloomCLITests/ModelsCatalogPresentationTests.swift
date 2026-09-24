import ProviderCore
import Testing

@testable import darkbloom

@Suite("Model catalog local-only presentation")
struct ModelsCatalogPresentationTests {
    @Test("a local Hugging Face copy does not make the downloaded catalog Gemma look retired")
    func extraGemmaDirectory() {
        let canonical = ModelInfo(
            id: "gemma-4-26b-qat-4bit", sizeBytes: 16_000_000_000,
            estimatedMemoryGb: 15.6)
        let localCopy = ModelInfo(
            id: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
            sizeBytes: 17_000_000_000, estimatedMemoryGb: 17.4)

        let lines = ModelsCatalogPresentation.otherLocalLines(
            localModels: [canonical, localCopy], catalogIDs: [canonical.id])

        #expect(lines.contains("  \(localCopy.id)  17.4 GB"))
        #expect(!lines.contains { $0.contains("  \(canonical.id)  ") })
        #expect(lines.contains("  A checkmark under Supported models means that catalog ID is downloaded."))
        #expect(lines.contains("  It does not confirm that this machine is receiving requests."))
        #expect(!lines.contains { $0.contains("no longer served") })
        #expect(ModelsCatalogPresentation.otherLocalLines(
            localModels: [canonical], catalogIDs: [canonical.id]).isEmpty)

        let filtered = ModelsCatalogPresentation.otherLocalLines(
            localModels: [canonical], catalogIDs: [])
        #expect(filtered.contains("Other local models (not in displayed catalog)"))
        #expect(filtered.contains("  With --type, other catalog model types can also appear here."))
        #expect(!filtered.contains { $0.contains("outside the network catalog") })
    }
}
