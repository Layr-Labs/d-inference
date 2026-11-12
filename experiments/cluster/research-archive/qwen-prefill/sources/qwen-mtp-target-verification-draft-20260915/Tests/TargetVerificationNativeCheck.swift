import Foundation
import MLX
import MLXLMCommon

/// Prospective tiny native fixture, compiled privately into Runtime like the
/// existing MTP tiny-forward SPI. It has no model, artifact or distributed claim.
@_spi(ClusterTesting) public enum TargetVerificationNativeCheck {
    public static func run() throws -> Data {
        try MLX.withError { native in
            do {
                var passed = [String]()
                for keep in 0...2 { try prefix(keep, check: native.check); passed.append("keep-\(keep)") }
                for continueAfterFirst in [false, true] {
                    try progressive(continueAfterFirst: continueAfterFirst, check: native.check)
                    passed.append(continueAfterFirst ? "progressive-continue" : "progressive-stop")
                }
                for afterEvaluation in [false, true] {
                    try failedStage(afterEvaluation: afterEvaluation, check: native.check)
                    passed.append(afterEvaluation ? "evaluated-failure-retired" : "open-binding-failure-retired")
                }
                return try JSONSerialization.data(withJSONObject: ["passed": passed,
                    "fabricatedNativeArrays": true, "modelExecution": false,
                    "bilateralVerification": false], options: [.sortedKeys])
            } catch { try native.check(); throw error }
        }
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError(message) }
    }

    private final class Fixture {
        let recurrent = try! CBv2RecurrentRequestState(spec: .init(layers: [
            .init(modelLayerIndex: 0, convShape: [1,1,1], convDType: .float32, ssmShape: [1,1,1,1])]))
        let row = CBv2FullSequenceKV(promptLength: 1, maxLength: 5, kvHeads: 1, headDim: 32)
        let cache = CBv2LayerCache(layerIndex: 1, kind: .init(attention: .full,
            headDim: 32, kvHeads: 1, queryHeads: 1, modelLayerIndex: 1))
        lazy var bank = CBv2LayerCacheBank(caches: [cache])
        var rows: [CBv2SequenceKV?] { [row] }

        func forward(_ evaluation: CBv2RecurrentStateEvaluation, increment: Float) throws -> MLXArray {
            let before = evaluation.inputState(modelLayerIndex: 0)
            let conv = (before?.conv ?? MLXArray.zeros([1,1,1])) + increment
            let ssm = (before?.ssm ?? MLXArray.zeros([1,1,1,1])) + increment
            try evaluation.stage(modelLayerIndex: 0, conv: conv, ssm: ssm)
            let values = broadcast(conv.reshaped([1,1,1,1]), to: [1,1,1,32])
            return cache.updateAndAttend(queries: MLXArray.zeros([1,1,1,32]), keys: values,
                                         values: values, scale: 1, sinks: nil)
        }
        func ordinary(_ increment: Float, check: () throws -> Void) throws {
            _ = bank.layerCaches(rowStates: [rows])
            let evaluation = try recurrent.bind()
            let output = try forward(evaluation, increment: increment)
            let roots = try evaluation.evaluate()
            eval([output] + roots + cache.innerState()); try check(); try evaluation.commit()
        }
        func requireFrontier(_ frontier: Int) throws {
            try TargetVerificationNativeCheck.require(row.absoluteOffset == frontier && row.retainedCount == frontier
                && cache.positionOffsets.asArray(Int32.self) == [Int32(frontier)], "KV/device frontier differs")
        }
        func confirmed() -> Float { recurrent.confirmedStateSnapshot()![0]!.ssm!.asArray(Float.self)[0] }
        func release() throws { bank.releaseBoundRows(); try recurrent.release() }
    }

    private static func prefix(_ count: Int, check: () throws -> Void) throws {
        let f = Fixture(); try f.ordinary(10, check: check)
        let transaction = try CBv2TargetVerification(base: 1, maximumSteps: 2, rows: f.rows)
        defer { try? transaction.discard(); try? f.release() }
        for increment in [Float(1), Float(2)] {
            _ = try transaction.stage(recurrent: f.recurrent, bank: f.bank, rows: f.rows, check: check,
                additionalTargets: { [] }, forward: { _, evaluation in try f.forward(evaluation, increment: increment) },
                validate: { _, frontier in try f.requireFrontier(frontier) })
        }
        try require(f.confirmed() == 10 && f.recurrent.state(modelLayerIndex: 0)!.ssm!.asArray(Float.self) == [13],
                    "Second stage did not read pending seed state, or target committed early")
        let beforeRebinds = f.cache.positionOffsetsHostRebuilds
        let frontier = try transaction.reconcile(keeping: count, bank: f.bank, rows: f.rows,
            check: check, validate: f.requireFrontier)
        try require(frontier == 1 + count && f.cache.positionOffsetsHostRebuilds == beforeRebinds + 1,
                    "Reconciliation omitted the device-offset rebind")
        let expected: Float = count == 0 ? 10 : (count == 1 ? 11 : 13)
        try require(f.confirmed() == expected, "Recurrent accepted prefix differs")
        let kv = f.row.snapshot().values.asArray(Float.self)
        let values: [Float] = count == 0 ? [10] : (count == 1 ? [10,11] : [10,11,13])
        try require(kv == values.flatMap { Array(repeating: $0, count: 32) }, "Rejected KV suffix remains visible")
        try f.ordinary(5, check: check); try f.requireFrontier(2 + count)
        try require(f.confirmed() == expected + 5, "Next ordinary decode did not use reconciled state")
        try f.release(); try require(f.cache.rows.isEmpty && f.recurrent.isReleased, "Fixture retained request roots")
    }

    private static func progressive(continueAfterFirst: Bool, check: () throws -> Void) throws {
        let f = Fixture(); try f.ordinary(10, check: check)
        let transaction = try CBv2TargetVerification(base: 1, maximumSteps: 2, rows: f.rows)
        defer { try? transaction.discard(); try? f.release() }
        for increment in [Float(1), Float(2)] {
            _ = try transaction.stage(recurrent: f.recurrent, bank: f.bank, rows: f.rows, check: check,
                additionalTargets: { [] }, forward: { _, evaluation in try f.forward(evaluation, increment: increment) },
                validate: { _, frontier in try f.requireFrontier(frontier) })
        }
        let first = try transaction.commitNext(check: check, validate: { committed, staged in
            try require(committed == 2 && staged == 3, "Progressive commit hid the pending frontier")
            try f.requireFrontier(staged)
        })
        try require(first == 2 && f.confirmed() == 11 && transaction.committedCount == 1
            && transaction.stagedCount == 2, "Seed did not commit independently of pending draft")
        // This is where a real owner must join both receipts, publish token2,
        // and receive its continue decision. The fixture fabricates that decision.
        if continueAfterFirst {
            let second = try transaction.commitNext(check: check, validate: { committed, staged in
                try require(committed == 3 && staged == 3, "Draft commit frontier differs")
                try f.requireFrontier(staged)
            })
            try require(second == 3 && f.confirmed() == 13, "Pending draft could not commit without reevaluation")
        }
        let kept = continueAfterFirst ? 2 : 1
        _ = try transaction.reconcile(keeping: kept, bank: f.bank, rows: f.rows,
                                      check: check, validate: f.requireFrontier)
        let expected: Float = continueAfterFirst ? 13 : 11
        try require(f.confirmed() == expected && f.row.absoluteOffset == 1 + kept,
                    "Stop rolled back a published input or kept an unpublished suffix")
        try f.ordinary(5, check: check)
        try require(f.confirmed() == expected + 5, "Progressive transaction contaminated subsequent decode")
    }

    private static func failedStage(afterEvaluation: Bool, check: () throws -> Void) throws {
        let f = Fixture(); try f.ordinary(10, check: check)
        let transaction = try CBv2TargetVerification(base: 1, maximumSteps: 2, rows: f.rows)
        var refused = false
        do {
            _ = try transaction.stage(recurrent: f.recurrent, bank: f.bank, rows: f.rows, check: check,
                additionalTargets: { [] }, forward: { _, evaluation in
                    let output = try f.forward(evaluation, increment: 1)
                    if !afterEvaluation { throw ProbeError("injected forward failure") }
                    return output
                }, validate: { _, _ in throw ProbeError("injected validation failure") })
        } catch { refused = true }
        try require(refused, "Injected failure was accepted")
        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try check()
        try transaction.discard(); try f.release()
        try require(f.recurrent.isReleased && f.cache.rows.isEmpty, "Failed transaction blocked request release")
    }
}
