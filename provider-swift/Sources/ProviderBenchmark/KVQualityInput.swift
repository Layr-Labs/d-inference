import Foundation

struct KVQualityInput: Codable, Sendable, Equatable {
    struct Case: Codable, Sendable, Equatable {
        let name: String
        let promptTokens: [Int]
        let maxTokens: Int
        let expectedText: String?
    }
    let modelID: String
    let expectedModelAggregateSHA256: String
    let concurrency: Int?
    let cases: [Case]
    var resolvedConcurrency: Int { concurrency ?? 1 }

    enum Failure: Error, Equatable {
        case invalidIdentity, invalidConcurrency, invalidCases, invalidTokens, inputTooLarge, unsupportedFields
    }

    func validate(modelID selected: String, vocabularySize: Int = 1_048_576) throws {
        guard modelID == selected, !modelID.isEmpty, modelID.utf8.count <= 512,
            expectedModelAggregateSHA256.utf8.count == 64,
            expectedModelAggregateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw Failure.invalidIdentity }
        guard [1, 2, 4].contains(resolvedConcurrency) else { throw Failure.invalidConcurrency }
        guard !cases.isEmpty, cases.count <= 16, Set(cases.map(\.name)).count == cases.count,
            cases.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.name.utf8.count <= 128 && ($0.expectedText?.utf8.count ?? 0) <= 65_536 })
        else { throw Failure.invalidCases }
        guard vocabularySize > 0, cases.allSatisfy({ sample in
            !sample.promptTokens.isEmpty && sample.promptTokens.count <= 32_768
                && (1...512).contains(sample.maxTokens)
                && sample.promptTokens.allSatisfy({ $0 >= 0 && $0 < vocabularySize })
        }) else { throw Failure.invalidTokens }
    }

    static func read(_ url: URL) throws -> (input: Self, data: Data) {
        let maximum = 8 << 20
        let resolved = url.resolvingSymlinksInPath()
        let facts = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard facts.isRegularFile == true, let size = facts.fileSize, size <= maximum else {
            throw Failure.inputTooLarge
        }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: maximum + 1 - bytes.count), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= maximum else { throw Failure.inputTooLarge }
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys).isSubset(of: ["modelID", "expectedModelAggregateSHA256", "concurrency", "cases"]),
            let cases = object["cases"] as? [[String: Any]],
            cases.allSatisfy({ Set($0.keys).isSubset(of: ["name", "promptTokens", "maxTokens", "expectedText"]) })
        else { throw Failure.unsupportedFields }
        return (try JSONDecoder().decode(Self.self, from: bytes), bytes)
    }
}
