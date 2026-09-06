import Foundation
@_spi(Diagnostics) import MLXLMCommon

/// A finite, exact token context. No chat-template rendering or generated-token
/// substitution is performed by this diagnostic.
struct TeacherForcedBenchmarkInput: Codable, Equatable {
    let modelID: String
    let expectedModelAggregateSHA256: String
    let promptTokens: [Int]
    let continuation: [Int]

    func request(modelID selected: String, vocabularySize: Int) throws
        -> CBv2TeacherForcedScoreRequest
    {
        guard modelID == selected, !modelID.isEmpty, modelID.utf8.count <= 512,
            expectedModelAggregateSHA256.utf8.count == 64,
            expectedModelAggregateSHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw TeacherForcedBenchmark.Failure.invalidInputIdentity }
        return try CBv2TeacherForcedScoreRequest(promptTokens: promptTokens,
            continuation: continuation, vocabularySize: vocabularySize)
    }

    static func readBounded(_ url: URL) throws -> Data {
        let maximum = 1 << 20
        // Hugging Face snapshots normally use file symlinks into their blob store.
        let resolved = url.resolvingSymlinksInPath()
        let facts = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard facts.isRegularFile == true, let size = facts.fileSize, size <= maximum else {
            throw TeacherForcedBenchmark.Failure.inputTooLarge
        }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: maximum + 1 - data.count), !part.isEmpty {
            data.append(part)
            guard data.count <= maximum else { throw TeacherForcedBenchmark.Failure.inputTooLarge }
        }
        return data
    }

    struct Declaration: Decodable {
        let vocabSize: Int?
        let textConfig: Text?
        let visionConfig: Vision?
        struct Text: Decodable {
            let vocabSize: Int
            enum CodingKeys: String, CodingKey { case vocabSize = "vocab_size" }
        }
        struct Vision: Decodable {}
        enum CodingKeys: String, CodingKey {
            case vocabSize = "vocab_size", textConfig = "text_config", visionConfig = "vision_config"
        }
        var vocabularySize: Int? { textConfig?.vocabSize ?? vocabSize }
    }
}
