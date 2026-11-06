import Foundation

private func require(_ value: @autoclosure () -> Bool) { precondition(value()) }
private func refuses(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected refusal") } catch {}
}

@main private struct ResourceSumChecks {
    static func main() throws {
        let budget = Gemma4MTPRemoteTargetBudget()
        let deadline = DispatchTime.now().uptimeNanoseconds + 55_000_000_000
        let actual = try Gemma4MTPRemoteTargetResources(budget:budget,deadline:deadline)
        let old = try UncachedRemoteTargetResources(budget:budget,deadline:deadline)
        try actual.attach(deadline:deadline,requestSHA256:budget.requestSHA256,maximumFrontier:143)
        try old.attach(deadline:deadline,requestSHA256:budget.requestSHA256,maximumFrontier:143)
        let initial = try actual.reservation()
        require(initial.nativeBytes == budget.nativeBytes && initial.hostBytes == budget.hostBytes)
        refuses { _ = try actual.receipt() }
        print("PASS initial-empty-cache-and-unobserved-refusal")

        func observe(_ free: Int = 2_000_000_000, _ active: Int = 1000) throws {
            let a = try actual.reservation(), b = try old.reservation()
            require(a.revision == b.revision && a.nativeBytes == b.nativeBytes && a.hostBytes == b.hostBytes)
            let os = QwenDenseStageLoadOSObservation(pressureLevel:1,actualFreeBytes:free)
            let native = QwenDenseStageLoadNativeObservation(activeBytes:active)
            try actual.acceptedObservation(a,os:os,native:native)
            try old.acceptedObservation(b,os:os,native:native)
        }
        func plan(_ bytes: Int, _ width: Int = 3) -> CBv2AttentionVerificationPlan {
            // Same 156 unique-name count as the actual 25-window/5-full plan.
            .init(steps:width,additionalArrays:(0..<156).map { .init(name:"fixture-term-\($0)",bytes:bytes+$0) })
        }
        try observe()
        try actual.admitVerification(plan(16_385)); try old.admitVerification(plan(16_385))
        let next = try actual.reservation()
        require(next.revision == initial.revision+1 && next.nativeBytes == 65_536+156*32_768)
        refuses { try actual.acceptedObservation(initial,os:.init(pressureLevel:1,actualFreeBytes:1),native:.init(activeBytes:1)) }
        refuses { _ = try actual.receipt() }
        try observe()
        print("PASS rounded-156-term-sum-and-new-revision-gate")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func equalReceipts() throws {
            let a = try encoder.encode(actual.receipt()), b = try encoder.encode(old.receipt())
            require(a == b)
        }
        try equalReceipts()
        for value in [65_537,1,32_000,16_385] {
            try actual.admitVerification(plan(value)); try old.admitVerification(plan(value))
            try observe(); try equalReceipts()
        }
        let retained = try actual.receipt()
        require(retained.verificationTerms.count == 156)
        require(retained.verificationNativeBytes == 156*81_920)
        require(retained.verificationTerms.allSatisfy { $0.logicalBytes >= 65_537 })
        print("PASS larger-then-smaller-plans-keep-all-named-maxima")

        let revisionBefore = try actual.reservation().revision
        for index in 0..<64 { try observe(2_000_000_000-index,1000+index) }
        try equalReceipts()
        let observed = try actual.receipt()
        let revisionAfter = try actual.reservation().revision
        require(revisionAfter == revisionBefore)
        require(observed.minimumActualFreeBytes == 2_000_000_000-63 && observed.maximumObservedActiveBytes == 1063)
        require(observed.observations == 70)
        print("PASS repeated-reservations-still-accept-every-fresh-observation")

        let beforeFailure = try actual.reservation()
        let giant = Int.max-Int.max%16_384
        let overflow = CBv2AttentionVerificationPlan(steps:1,additionalArrays:[.init(name:"overflow",bytes:giant)])
        refuses { try actual.admitVerification(overflow) }
        let afterFailure = try actual.reservation()
        require(afterFailure.revision == beforeFailure.revision && afterFailure.nativeBytes == beforeFailure.nativeBytes)
        try equalReceipts()
        print("PASS checked-overflow-precedes-ledger-and-revision-mutation")

        refuses { try actual.admitVerification(plan(1,4)) }
        let afterShape = try actual.reservation()
        require(afterShape.revision == beforeFailure.revision && afterShape.nativeBytes == beforeFailure.nativeBytes)
        try actual.checkControlLifetime(); actual.poison()
        refuses { _ = try actual.reservation() }; refuses { _ = try actual.receipt() }
        print("PASS shape-and-poison-refusals-preserved")
    }
}
