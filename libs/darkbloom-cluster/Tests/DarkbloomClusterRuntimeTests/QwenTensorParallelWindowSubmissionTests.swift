import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// A verify window is evaluated whole by default
/// (`QwenTensorParallelTargetWindow.layerStride`), and
/// `DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION=1` submits it layer by layer for
/// a diagnosis: evaluation order only, so a window has the same logits, hidden
/// rows and settled history either way, on both ranks; the choice is bound
/// into the load agreement. GPU checks run with `QWEN_TP_MTP_GPU=1`.
@Suite(.serialized)
struct QwenTensorParallelWindowSubmissionTests {
    @Test func windowsAreEvaluatedWholeUnlessTheDiagnosisSaysByLayer() {
        let whole = ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION"] != "1"
        #expect(QwenTensorParallelTargetWindow.submitsByLayer == !whole)
        #expect(QwenTensorParallelTargetWindow.layerStride(packed: false)
            == (whole ? 0 : QwenTensorParallelBatchSession.decodeLayerStride))
        // A packed-storage window is always evaluated whole (its refused writes are checked first).
        #expect(QwenTensorParallelTargetWindow.layerStride(packed: true) == 0)
        // A bench's own stride wins over both.
        QwenTensorParallelBatchSession.$layerStride.withValue(3) {
            #expect(QwenTensorParallelTargetWindow.layerStride(packed: false) == 3)
        }
        #expect(QwenTensorParallelTargetWindow.agreementFields
            == ["qwen-tensor-parallel-window-submission-v1", whole ? "whole" : "by-layer"])
    }

    private final class Wire: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        private var result: [Float] = []
        private var generation = 0, leaving = 0
        func sum(_ input: MLXArray, rank: Int) -> MLXArray {
            let value = input.asArray(Float.self)
            condition.lock()
            let deadline = Date().addingTimeInterval(30)
            while leaving > 0 { precondition(condition.wait(until: deadline)) }
            let entered = generation
            precondition(values[rank] == nil)
            values[rank] = value; shapes[rank] = input.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                result = zip(values[0]!, values[1]!).map(+); leaving = 2; condition.broadcast()
            } else {
                while leaving == 0 && generation == entered { precondition(condition.wait(until: deadline)) }
            }
            let output = result; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; result = []; generation += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(output, input.shape)
        }
    }
    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray { wire.sum(value, rank: rank) }
    }
    private final class Owner: @unchecked Sendable {
        let model: QwenTensorParallelModel, host: CBv2StageKVHost
        var sessions: [QwenTensorParallelBatchSession] = []
        var outputs: [Data] = [], failure: Error?
        init(_ model: QwenTensorParallelModel, width: Int) throws {
            self.model = model
            host = try .init(model: model.model, kind: .paged, lanes: width,
                maximumTokensPerRequest: 256, maximumChunkTokens: 64)
        }
    }
    private final class Work: @unchecked Sendable {
        let body: (Owner) throws -> Void
        init(_ body: @escaping (Owner) throws -> Void) { self.body = body }
    }
    /// Both ranks at once, with a layer stride of their own (nil: the product's).
    private func paired(_ owners: [Owner], stride: Int? = nil, _ body: @escaping (Owner) throws -> Void) throws {
        let work = Work(body)
        owners.forEach { $0.failure = nil }
        DispatchQueue.concurrentPerform(iterations: 2) { rank in
            Device.withDefaultDevice(.gpu) {
                QwenTensorParallelBatchSession.$layerStride.withValue(stride) {
                    do { try work.body(owners[rank]) } catch { owners[rank].failure = error }
                }
            }
        }
        for owner in owners { if let failure = owner.failure { throw failure } }
    }
    private func pair(rows: [Int]) throws -> [Owner] {
        let fixture = QwenTensorParallelFixtures.checkpoint(hidden: 256, layers: 4,
            heads: 4, kvHeads: 2, vocabulary: 256)
        var root = try JSONSerialization.jsonObject(with: fixture.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["max_position_embeddings"] = 256; root["text_config"] = text
        let configuration = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let wire = Wire()
        let owners = try (0..<2).map { rank -> Owner in
            let model = try QwenTensorParallelModel.assemble(configurationData: configuration,
                role: .shard(rank: rank, size: 2), reduction: Rank(rank, wire)) { _, keep in
                for (name, value) in fixture.tensors { try keep(name, value) }
            }
            return try Owner(model, width: rows.count)
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-window-submission-fixture",
            vocabularySize: 256, hiddenSize: 256, activationDType: "bfloat16",
            maximumPromptTokens: 128, maximumChunkTokens: 64, maximumOutputTokens: 32, maximumContextTokens: 256)
        for (lane, row) in rows.enumerated() {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: (0..<(7 + 2 * row)).map { ($0 * 17 + row * 3 + 2) % 256 },
                chunkSize: 5, outputCount: 24, stopTokenIDs: [])
            for owner in owners {
                owner.sessions.append(try .init(model: owner.model, configuration: configuration,
                    host: owner.host, request: request))
            }
            while owners[0].sessions[lane].schedule.committedPromptTokens < request.promptCount {
                try paired(owners) { _ = try $0.sessions[lane].prefill(check: {}) }
            }
        }
        return owners
    }
    private static func bytes(_ value: MLXArray) -> Data { eval(value); return value.asData(access: .copy).data }
    private func history(_ session: QwenTensorParallelBatchSession) throws -> [Data] {
        var roots: [MLXArray] = []
        for row in session.state.rows.compactMap({ $0 }) {
            let view = row.snapshot(); roots += [view.keys, view.values]
        }
        let recurrent = try #require(session.state.recurrent.confirmedStateSnapshot())
        for index in recurrent.keys.sorted() {
            roots += [try #require(recurrent[index]!.conv), try #require(recurrent[index]!.ssm)]
        }
        return roots.map(Self.bytes)
    }

    /// A window evaluated whole and one submitted layer by layer: the same
    /// logits, hidden rows and settled history on both ranks, one row and two.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_MTP_GPU"] == "1"))
    func wholeAndLayeredWindowsAreBitwise() throws {
        try Device.withDefaultDevice(.gpu) {
            for (width, columns) in [(1, 4), (2, 3)] {
                let rows = Array(0..<width)
                let tokens = rows.flatMap { row in (0..<columns).map { Int32((row * 29 + $0 * 13 + 5) % 256) } }
                var results: [[Data]] = []
                for stride in [nil, 0] as [Int?] {
                    let owners = try pair(rows: rows)
                    try paired(owners, stride: stride) { owner in
                        let built = try QwenTensorParallelBatchSession.beginWindows(owner.sessions,
                            tokens: MLXArray(tokens).reshaped([width, columns]))
                        eval(built.outputs + built.roots)
                        try QwenTensorParallelBatchSession.confirmWindows(owner.sessions, check: {})
                        eval(try QwenTensorParallelBatchSession.settleWindows(owner.sessions,
                            keeping: Array(repeating: columns - 1, count: width)))
                        try QwenTensorParallelBatchSession.confirmSettledWindows(owner.sessions, check: {})
                        owner.outputs = built.outputs.map(Self.bytes)
                    }
                    var all: [Data] = []
                    for owner in owners {
                        all += owner.outputs
                        for session in owner.sessions { all += try history(session) }
                        for session in owner.sessions { try session.retire() }
                        #expect(owner.host.isDrained)
                    }
                    results.append(all)
                }
                #expect(results[0].count == results[1].count && !results[0].isEmpty)
                let differing = zip(results[0], results[1]).filter { $0 != $1 }.count
                #expect(differing == 0, "B=\(width) S=\(columns): \(differing) outputs differ between layered and whole windows")
            }
        }
    }
}
