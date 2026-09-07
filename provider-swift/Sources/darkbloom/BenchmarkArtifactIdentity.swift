import Foundation

/// A report may leave this guard only after the measured files still match the
/// expected aggregate. Measurement progress remains on stderr in each harness.
enum BenchmarkArtifactIdentity {
    struct Receipt: Codable, Equatable {
        let modelID: String
        let modelDirectory: String
        let expectedModelAggregateSHA256: String
        let beforeModelAggregateSHA256: String
        let afterModelAggregateSHA256: String
    }

    struct Measurement<Result> {
        let result: Result
        let receipt: Receipt?

        func json(_ reportJSON: String) throws -> String {
            guard let receipt else { return reportJSON }
            guard var object = try JSONSerialization.jsonObject(with: Data(reportJSON.utf8)) as? [String: Any] else {
                throw Failure.invalidReport
            }
            object["artifactIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
            return String(decoding: try JSONSerialization.data(withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        }
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case invalidExpectedHash, beforeMismatch, afterMismatch, invalidReport
        var description: String {
            switch self {
            case .invalidExpectedHash: "--model-directory requires --expected-model-aggregate-sha256 with 64 lowercase hexadecimal characters"
            case .beforeMismatch: "Exact model directory does not match the expected aggregate before measurement"
            case .afterMismatch: "Exact model directory no longer matches the expected aggregate after measurement; no report published"
            case .invalidReport: "Benchmark produced an invalid report object"
            }
        }
    }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func measure<Result>(
        modelID: String, modelDirectory: URL, expectedHash: String?,
        readHash: () -> String?, operation: () async throws -> Result
    ) async throws -> Measurement<Result> {
        guard let expectedHash else { return .init(result: try await operation(), receipt: nil) }
        guard validHash(expectedHash) else { throw Failure.invalidExpectedHash }
        guard let before = readHash(), before == expectedHash else { throw Failure.beforeMismatch }
        let result = try await operation()
        guard let after = readHash(), after == expectedHash else { throw Failure.afterMismatch }
        return .init(result: result, receipt: .init(
            modelID: modelID, modelDirectory: modelDirectory.path,
            expectedModelAggregateSHA256: expectedHash,
            beforeModelAggregateSHA256: before, afterModelAggregateSHA256: after))
    }
}
