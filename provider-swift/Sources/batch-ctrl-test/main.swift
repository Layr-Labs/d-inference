// batch-ctrl-test — standalone validation of the continuous-batching
// composition control vector (encode/decode round-trip). `swift test` is broken
// in this toolchain (pre-existing XCTest import), so the protocol — the riskiest
// Phase 3 piece — is validated here instead. Mirrors Tests/.../ClusterBatchControlTests.

import Foundation
import ProviderCore

final class Counter { var failures = 0 }

func run() {
let counter = Counter()
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ok: \(msg)") }
    else { print("  FAIL: \(msg)"); counter.failures += 1 }
}
print("== batch-ctrl-test: composition round-trip ==")

// 1. Full step: survivors + ragged admit.
do {
    let comp = ClusterBatchComposition(
        command: .step, bNext: 5, keepIndices: [0, 2, 3],
        admit: [
            ClusterAdmitRow(promptTokens: [10, 11, 12], leftPadding: 0, maxTokens: 64),
            ClusterAdmitRow(promptTokens: [99], leftPadding: 2, maxTokens: 128),
        ])
    let d = ClusterBatchComposition.decode(comp.encodeVector())
    check(d.command == .step, "command=step")
    check(d.bNext == 5, "bNext=5")
    check(d.keepIndices == [0, 2, 3], "keepIndices preserved")
    check(d.admit.count == 2, "nAdmit=2")
    check(d.admit[0].promptTokens == [10, 11, 12] && d.admit[0].maxTokens == 64, "admit[0] prompt+maxTokens")
    check(d.admit[1].promptTokens == [99] && d.admit[1].leftPadding == 2, "admit[1] prompt+leftPadding")
}

// 2. Evict-only (pure decode step).
do {
    let comp = ClusterBatchComposition(command: .step, bNext: 2, keepIndices: [1, 4], admit: [])
    let d = ClusterBatchComposition.decode(comp.encodeVector())
    check(d.keepIndices == [1, 4] && d.admit.isEmpty, "evict-only round-trip")
}

// 3. Admit-only (cold start).
do {
    let comp = ClusterBatchComposition(command: .step, bNext: 1, keepIndices: [],
        admit: [ClusterAdmitRow(promptTokens: [1, 2, 3, 4, 5], leftPadding: 0, maxTokens: 32)])
    let d = ClusterBatchComposition.decode(comp.encodeVector())
    check(d.keepIndices.isEmpty && d.admit.first?.promptTokens == [1, 2, 3, 4, 5], "admit-only round-trip")
}

// 4. Shutdown / idle commands.
do {
    check(ClusterBatchComposition.decode(ClusterBatchComposition.shutdown.encodeVector()).command == .shutdown, "shutdown")
    check(ClusterBatchComposition.decode(ClusterBatchComposition.idle.encodeVector()).command == .idle, "idle")
}

// 5. Fixed width regardless of composition.
do {
    let a = ClusterBatchComposition.idle.encodeVector()
    let b = ClusterBatchComposition(command: .step, bNext: 3, keepIndices: [0, 1],
        admit: [ClusterAdmitRow(promptTokens: Array(0..<100), leftPadding: 0, maxTokens: 16)]).encodeVector()
    check(a.count == BATCH_CTRL_WIDTH && b.count == BATCH_CTRL_WIDTH, "fixed width = \(BATCH_CTRL_WIDTH)")
}

// 6. Ragged admit order + padding preserved.
do {
    let admit = [
        ClusterAdmitRow(promptTokens: [7, 7], leftPadding: 3, maxTokens: 10),
        ClusterAdmitRow(promptTokens: [8, 8, 8, 8], leftPadding: 1, maxTokens: 20),
        ClusterAdmitRow(promptTokens: [9], leftPadding: 0, maxTokens: 30),
    ]
    let d = ClusterBatchComposition.decode(
        ClusterBatchComposition(command: .step, bNext: 3, keepIndices: [], admit: admit).encodeVector())
    var ok = d.admit.count == 3
    for i in 0..<min(3, d.admit.count) {
        ok = ok && d.admit[i].promptTokens == admit[i].promptTokens
            && d.admit[i].leftPadding == admit[i].leftPadding
            && d.admit[i].maxTokens == admit[i].maxTokens
    }
    check(ok, "ragged admit order + padding preserved")
}

if counter.failures == 0 { print("\nPASS: all composition round-trips correct.") }
else { print("\nFAIL: \(counter.failures) checks failed."); exit(1) }
}

run()
