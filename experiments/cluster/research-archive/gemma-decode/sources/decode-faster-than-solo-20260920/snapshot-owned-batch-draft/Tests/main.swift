import Foundation

@main enum SnapshotBatchControls {
    enum Failed: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failed.assertion(message) }
    }
    static func refused(_ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch is Gemma4MTPPullSnapshotPolicy.Failure { rejected = true }
        try require(rejected,"Invalid batch chronology/policy was admitted")
    }
    static func prepared() throws -> Gemma4MTPPullSnapshotBatchProgress {
        var p = Gemma4MTPPullSnapshotBatchProgress(); try p.begin(); try p.preparedAfterFence(); return p
    }
    static func transferred() throws -> Gemma4MTPPullSnapshotBatchProgress {
        var p = try prepared()
        for index in 0..<7 { try p.outputRetained(index); try p.transferCompleted(index) }
        return p
    }
    static func main() throws {
        var labels: [String] = []
        let legacy = try Gemma4MTPPullSnapshotPolicy(requested:nil)
        try require(legacy == .perTensor && legacy.scopeComponents.isEmpty,"Absent policy changed legacy scope")
        labels.append("absence-preserves-legacy-scope")
        let batch = try Gemma4MTPPullSnapshotPolicy(requested:Gemma4MTPPullSnapshotPolicy.ownedBatch.rawValue)
        try require(batch == .ownedBatch && batch.scopeComponents == ["snapshotPolicy="+batch.rawValue],"Explicit scope differs")
        labels.append("explicit-policy-binds-scope")
        for invalid in ["", "ownedBatch", Gemma4MTPPullSnapshotPolicy.perTensor.rawValue,
                        Gemma4MTPPullSnapshotPolicy.ownedBatch.rawValue+" "] {
            try refused { _ = try Gemma4MTPPullSnapshotPolicy(requested:invalid) }
        }
        labels.append("unknown-and-implicit-aliases-refused")
        var p = Gemma4MTPPullSnapshotBatchProgress()
        try refused { try p.preparedAfterFence() }; try refused { try p.outputRetained(0) }
        labels.append("entry-boundary-required")
        try p.begin(); try refused { try p.begin() }; try refused { try p.finishAfterFence() }
        labels.append("reentry-and-early-final-boundary-refused")
        p = try prepared(); try refused { try p.transferCompleted(0) }
        labels.append("retain-before-native-completion-required")
        try refused { try p.outputRetained(1) }; try refused { try p.outputRetained(-1) }
        labels.append("wire-order-exact")
        try p.outputRetained(0); try refused { try p.outputRetained(1) }
        try p.transferCompleted(0); try refused { try p.transferCompleted(0) }
        labels.append("each-cpu-completion-before-next-transfer")
        p = try transferred()
        try require(p.phase == .transferring && p.completed == 7 && p.boundaries == 1,"CPU completion substituted for final fence")
        try refused { try p.outputRetained(7) }
        labels.append("seven-transfer-limit-and-final-fence-required")
        try p.finishAfterFence()
        try require(p.phase == .complete && p.retained == 7 && p.completed == 7 && p.boundaries == 2,"Successful counts differ")
        try refused { try p.finishAfterFence() }; try refused { try p.begin() }
        labels.append("completion-counts-and-reuse-refusal")
        // Model each point where the actual native wrapper catch poisons the
        // retained batch. These are scalar controls, NOT native fault injection.
        var prefixes: [Gemma4MTPPullSnapshotBatchProgress] = [.init()]
        var current = Gemma4MTPPullSnapshotBatchProgress(); try current.begin(); prefixes.append(current)
        try current.preparedAfterFence(); prefixes.append(current)
        for index in 0..<7 {
            try current.outputRetained(index); prefixes.append(current)
            try current.transferCompleted(index); prefixes.append(current)
        }
        for var failed in prefixes {
            let roots = failed.retained, completed = failed.completed
            failed.poison()
            try require(failed.phase == .failed && failed.retained == roots && failed.completed == completed,"Poison erased root obligations")
            try refused { try failed.begin() }; try refused { try failed.finishAfterFence() }
            try refused { try failed.requireNext(completed) }
        }
        labels.append("every-partial-prefix-poisons-with-obligations-intact")
        p = try transferred(); p.poison()
        try require(p.retained == 7 && p.completed == 7 && p.boundaries == 1,"Failed final fence implied release")
        try refused { try p.finishAfterFence() }
        labels.append("failed-final-fence-never-completes")
        try require(labels.count == 12,"Control count differs")
        let report: [String:Any] = ["schema":"gemma4_owned_snapshot_batch_cpu_controls_v1",
            "passed":true,"groups":labels,"groupCount":labels.count,"modelExecuted":false,
            "nativeTransferExecuted":false,"nativeFailureLifetimeQualified":false]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
