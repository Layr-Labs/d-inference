import Foundation
import Testing
@_spi(Diagnostics) import MLXLMCommon
@testable import ProviderBenchmark

@Suite("Bounded ordinary-context benchmark input and controls")
struct TeacherForcedBenchmarkTests {
    private func input(model: String = "target", hash: String = String(repeating: "a", count: 64),
        prompt: [Int] = [1, 2], continuation: [Int] = [2]) -> TeacherForcedBenchmarkInput
    {
        .init(modelID: model, expectedModelAggregateSHA256: hash,
            promptTokens: prompt, continuation: continuation)
    }

    @Test func identityTokensAndExplicitBackendAreRequired() throws {
        let request = try input().request(modelID: "target", vocabularySize: 4)
        #expect(request.promptTokens == [1, 2] && request.continuation == [2])
        for value in [input(model: "other"), input(hash: "not-a-hash"),
            input(hash: String(repeating: "A", count: 64)), input(prompt: []),
            input(continuation: [-1]), input(continuation: [4]),
            input(continuation: Array(repeating: 2, count: 257))] {
            #expect(throws: (any Error).self) {
                try value.request(modelID: "target", vocabularySize: 4)
            }
        }
        for backend in ["auto", "", "PAGED", "other"] {
            #expect(throws: TeacherForcedBenchmark.Failure.self) {
                try TeacherForcedBenchmark.validateBackend(backend)
            }
        }
        try TeacherForcedBenchmark.validateBackend("contiguous")
        try TeacherForcedBenchmark.validateBackend("paged")
    }

    @Test func fileBoundAndMalformedInputRefuseBeforeModelWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.json")
        let bytes = try JSONEncoder().encode(input())
        try bytes.write(to: file)
        #expect(try TeacherForcedBenchmarkInput.readBounded(file) == bytes)
        let link = root.appendingPathComponent("snapshot-input.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try TeacherForcedBenchmarkInput.readBounded(link) == bytes)
        try Data(repeating: 32, count: (1 << 20) + 1).write(to: file)
        #expect(throws: TeacherForcedBenchmark.Failure.self) {
            try TeacherForcedBenchmarkInput.readBounded(file)
        }
        #expect(throws: TeacherForcedBenchmark.Failure.self) {
            try TeacherForcedBenchmarkInput.readBounded(root)
        }
        try Data("{bad json".utf8).write(to: file)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TeacherForcedBenchmarkInput.self,
                from: TeacherForcedBenchmarkInput.readBounded(file))
        }
    }

    @Test func textTowerDeclarationSuppliesActualVocabulary() throws {
        for (json, expected, vision) in [
            (#"{"vocab_size":17}"#, 17, false),
            (#"{"vocab_size":9,"text_config":{"vocab_size":23},"vision_config":{}}"#, 23, true)
        ] {
            let declaration = try JSONDecoder().decode(TeacherForcedBenchmarkInput.Declaration.self,
                from: Data(json.utf8))
            #expect(declaration.vocabularySize == expected)
            #expect((declaration.visionConfig != nil) == vision)
        }
    }

    private func snapshot(top1: [Int] = [2], recordArgMax: Int = 2, forcedBits: UInt32 = Float(1).bitPattern,
        nanCount: Int = 0) throws -> CBv2TeacherForcedScoreSnapshot
    {
        let record: [String: Any] = [
            "index": 0, "contextLength": 2, "forcedToken": 2, "logitDType": "bfloat16",
            "vocabularySize": 4, "argMaxID": recordArgMax, "topTwoIDs": [2, 1],
            "argMaxValueBits": Float(1).bitPattern,
            "topTwoValueBits": [Float(1).bitPattern, Float(0).bitPattern],
            "forcedTokenValueBits": forcedBits, "logSumExpBits": Float(2).bitPattern,
            "forcedLogProbabilityBits": Float(-1).bitPattern, "nllBits": Float(1).bitPattern,
            "topTwoMarginBits": Float(1).bitPattern, "nanCount": nanCount, "infiniteCount": 0,
        ]
        return try JSONDecoder().decode(CBv2TeacherForcedScoreSnapshot.self,
            from: JSONSerialization.data(withJSONObject: ["top1": top1, "records": [record]]))
    }

    private func activity(prefill: Int = 1, decode: Int = 0) -> TeacherForcedBenchmark.Activity {
        .init(before: .none, after: .init(prefillChunksExecuted: prefill, decodeForwardsExecuted: decode))
    }

    @Test func neutralControlIsObservationalAndEveryFaultRemainsInconclusive() throws {
        let good = try snapshot()
        let counts = Array(repeating: activity(), count: 3)
        func reasons(_ plain: [Int] = [2], first: CBv2TeacherForcedScoreSnapshot? = nil,
            repeated: CBv2TeacherForcedScoreSnapshot? = nil,
            counts: [TeacherForcedBenchmark.Activity]? = nil) -> [String]
        {
            TeacherForcedBenchmark.controlReasons(plain: plain, first: first ?? good,
                repeated: repeated ?? good, activity: counts ?? Array(repeating: activity(), count: 3), count: 1)
        }
        #expect(reasons().isEmpty)
        #expect(!reasons([1]).isEmpty)
        #expect(!reasons([], counts: counts).isEmpty)
        #expect(!reasons(repeated: try snapshot(forcedBits: Float(0.5).bitPattern)).isEmpty)
        let discrepant = try snapshot(recordArgMax: 1)
        let discrepancy = "independent diagnostic argmax differs from scored top1"
        #expect(reasons(first: discrepant, repeated: discrepant).contains(discrepancy))
        #expect(reasons(repeated: discrepant).contains(discrepancy))
        let nonfinite = try snapshot(forcedBits: Float.nan.bitPattern, nanCount: 1)
        #expect(reasons(first: nonfinite, repeated: nonfinite).contains("nonfinite score evidence"))
        #expect(!reasons(counts: []).isEmpty)
        #expect(!reasons(counts: Array(repeating: activity(prefill: 0), count: 3)).isEmpty)
        #expect(!reasons(counts: [activity(), activity(prefill: 2), activity()]).isEmpty)
        #expect(!reasons(counts: Array(repeating: activity(decode: 1), count: 3)).isEmpty)
    }
}
