import Foundation

private enum FixtureFailure: Error { case assertion(String), primary, cleanup }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.assertion(message) }
}

private func rejected(_ body: () throws -> Void) throws {
    do { try body() }
    catch { return }
    throw FixtureFailure.assertion("Expected rejection")
}

private func identity(_ fingerprint: Character = "a", requestID: UUID = UUID(),
    epoch: UUID = UUID()
) -> QwenLayerStageResidentRequestIdentity {
    .init(requestID: requestID, epoch: epoch, recordedRequestFingerprint: String(repeating: String(fingerprint), count: 64))
}

private final class ScopeSentinel {}

@main
enum QwenLayerStageResidentLifecycleCheck {
    static func main() throws {
        var passed = [String]()
        var overlap: ResidentLifecycleOverlapResult?
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed.append(name)
        }

        try test("invalid limit refuses before fake model construction") {
            for limit in [-1, 0, 17, Int.max] {
                let ledger = ResidentFixtureLedger()
                try rejected { _ = try ResidentFixtureOwner(maximumRequests: limit, ledger: ledger) }
                try require(ledger.loads == 0, "Invalid cohort loaded a model")
            }
        }
        try test("A B A histories keep one model and create three retired requests") {
            let ledger = ResidentFixtureLedger()
            let owner = try ResidentFixtureOwner(maximumRequests: 3, ledger: ledger)
            let a = [1, 2, 3], b = [8, 5]
            let first = try owner.run(identity("a"), history: a)
            let middle = try owner.run(identity("b"), history: b)
            let last = try owner.run(identity("a"), history: a)
            try require(first.history == last.history && middle.history == b, "History leaked between requests")
            try require(first.requestID != last.requestID, "Request UUID was not fresh")
            try require(first.modelLoadID == middle.modelLoadID && first.modelLoadID == last.modelLoadID,
                "The model was reloaded")
            try require(first.originalLoadReceipt == last.originalLoadReceipt, "Original receipt was rewritten")
            try require(ledger.loads == 1 && ledger.requestConstructions == 3 && ledger.requestRetirements == 3 &&
                ledger.zeroFrontiers == 3 && ledger.observedRequest == nil, "Request scope was reused or retained")
            try require(ledger.observedModel != nil && owner.snapshot.completedRequestScopes == 3 &&
                !owner.snapshot.releaseCallbackCompleted, "Per-request success claimed model release")
            try owner.release()
            try require(ledger.observedModel == nil && ledger.modelDeinits == 1 &&
                owner.snapshot.releaseCallbackCompleted && !owner.snapshot.failed, "Final model release failed")
        }
        try test("unstarted owner can explicitly release") {
            let ledger = ResidentFixtureLedger()
            let owner = try ResidentFixtureOwner(maximumRequests: 1, ledger: ledger)
            try owner.release()
            try require(ledger.requestConstructions == 0 && ledger.modelDeinits == 1 &&
                owner.snapshot.completedRequestScopes == 0, "Empty cleanup fabricated a request")
        }
        try test("sixteen request ceiling rejects before the seventeenth body") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 16)
            var bodies = 0
            for _ in 0..<16 { try gate.withRequest(identity: identity()) { bodies += 1 } }
            try rejected { try gate.withRequest(identity: identity()) { bodies += 1 } }
            try require(bodies == 16 && gate.snapshot.completedRequestScopes == 16 && gate.snapshot.failed,
                "Cohort limit did not fence the body")
            try gate.withModelRelease {}
        }
        try test("duplicate request UUID rejects with a fresh epoch") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 2), id = UUID()
            try gate.withRequest(identity: identity(requestID: id)) {}
            var ran = false
            try rejected { try gate.withRequest(identity: identity("b", requestID: id)) { ran = true } }
            try require(!ran && gate.snapshot.admittedRequests == 1 && gate.snapshot.failed, "UUID replay entered body")
        }
        try test("duplicate epoch rejects with a fresh request UUID") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 2), epoch = UUID()
            try gate.withRequest(identity: identity(epoch: epoch)) {}
            var ran = false
            try rejected { try gate.withRequest(identity: identity("b", epoch: epoch)) { ran = true } }
            try require(!ran && gate.snapshot.admittedRequests == 1 && gate.snapshot.failed, "Epoch replay entered body")
        }
        try test("malformed fingerprint refuses before body") {
            for pin in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                        String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
                let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
                var ran = false
                try rejected {
                    try gate.withRequest(identity: .init(requestID: UUID(), epoch: UUID(), recordedRequestFingerprint: pin)) {
                        ran = true
                    }
                }
                try require(!ran && gate.snapshot.admittedRequests == 0, "Malformed identity entered body")
            }
        }
        try test("autorelease scope ends before callback completion") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            weak var weakSentinel: ScopeSentinel?
            let value: Int = try gate.withRequest(identity: identity()) {
                let value = autoreleasepool { () -> Int in
                    let sentinel = ScopeSentinel(); weakSentinel = sentinel
                    return 7
                }
                try require(weakSentinel == nil && gate.snapshot.requestScopeActive &&
                    gate.snapshot.completedRequestScopes == 0, "Scope completion was published early")
                return value
            }
            try require(value == 7 && gate.snapshot.completedRequestScopes == 1, "CPU result was lost")
        }
        for (name, fault, expected) in [
            ("committed forward failure", ResidentFixtureFault.forwardAfterCommit, ResidentFixtureError.injectedForward),
            ("request close failure", .close, .injectedClose),
            ("late check failure after scope", .lateCheck, .injectedLateCheck)
        ] {
            try test(name + " poisons reuse and still allows final cleanup") {
                let ledger = ResidentFixtureLedger()
                let owner = try ResidentFixtureOwner(maximumRequests: 2, ledger: ledger)
                do { _ = try owner.run(identity(), history: [1, 2], fault: fault); throw FixtureFailure.assertion("Missing fault") }
                catch let error as ResidentFixtureError { try require(error == expected, "Primary failure was replaced") }
                try rejected { _ = try owner.run(identity("b"), history: [3]) }
                try require(ledger.requestConstructions == 1 && ledger.requestRetirements == 1 &&
                    ledger.observedRequest == nil && owner.snapshot.completedRequestScopes == 0 &&
                    owner.snapshot.failed && !owner.snapshot.requestScopeActive, "Failed request resumed")
                try owner.release()
                try require(ledger.modelDeinits == 1 && owner.snapshot.releaseCallbackCompleted && owner.snapshot.failed,
                    "Cleanup erased failure or retained weights")
            }
        }
        try test("retained request cannot become a successful scope") {
            let ledger = ResidentFixtureLedger()
            let owner = try ResidentFixtureOwner(maximumRequests: 1, ledger: ledger)
            do { _ = try owner.run(identity(), history: [1], fault: .escapeRequest); throw FixtureFailure.assertion("Missing escape") }
            catch let error as ResidentFixtureError { try require(error == .retainedRequest, "Wrong escape error") }
            try require(owner.snapshot.failed && owner.snapshot.completedRequestScopes == 0 &&
                ledger.observedRequest != nil, "Retained request was accepted")
            ledger.injectedEscapedObject = nil
            try owner.release()
        }
        try test("retained model fails final release without a retry or success claim") {
            let ledger = ResidentFixtureLedger()
            let owner = try ResidentFixtureOwner(maximumRequests: 1, ledger: ledger)
            _ = try owner.run(identity(), history: [1], fault: .escapeModel)
            do { try owner.release(); throw FixtureFailure.assertion("Missing model escape") }
            catch let error as ResidentFixtureError { try require(error == .retainedModel, "Wrong release error") }
            try require(owner.snapshot.releaseAttempted && !owner.snapshot.releaseCallbackCompleted && owner.snapshot.failed,
                "Retained model was reported released")
            ledger.injectedEscapedObject = nil
            try rejected { try owner.release() }
            try require(ledger.observedModel == nil && !owner.snapshot.releaseCallbackCompleted,
                "Later ARC release rewrote failed evidence")
        }
        try test("caught request reentry invalidates outer success") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 2)
            var nested = false
            try rejected {
                try gate.withRequest(identity: identity()) {
                    do { try gate.withRequest(identity: identity("b")) { nested = true } } catch {}
                }
            }
            try require(!nested && gate.snapshot.admittedRequests == 1 && gate.snapshot.completedRequestScopes == 0 &&
                gate.snapshot.failed && !gate.snapshot.requestScopeActive, "Caught reentry escaped fencing")
            try gate.withModelRelease {}
        }
        try test("release during a request never runs its body and invalidates the request") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            var releaseBodies = 0
            try rejected {
                try gate.withRequest(identity: identity()) {
                    do { try gate.withModelRelease { releaseBodies += 1 } } catch {}
                }
            }
            try require(releaseBodies == 0 && gate.snapshot.completedRequestScopes == 0, "Active model was released")
            try gate.withModelRelease { releaseBodies += 1 }
            try require(releaseBodies == 1 && gate.snapshot.failed, "Final cleanup reset the failure")
        }
        try test("release failure preserves primary error and refuses later work") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            var primary: String?
            do { try gate.withRequest(identity: identity()) { throw FixtureFailure.primary } }
            catch { primary = String(describing: error) }
            do { try gate.withModelRelease { throw FixtureFailure.cleanup } }
            catch { try require(String(describing: error) == "cleanup", "Cleanup error was replaced") }
            try require(primary == "primary", "Original request error was overwritten")
            var ran = false
            try rejected { try gate.withRequest(identity: identity()) { ran = true } }
            try rejected { try gate.withModelRelease { ran = true } }
            try require(!ran && gate.snapshot.failed && !gate.snapshot.releaseCallbackCompleted,
                "Failed release resumed")
        }
        try test("caught request reentry during release invalidates release completion") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            var ran = false
            try rejected {
                try gate.withModelRelease {
                    do { try gate.withRequest(identity: identity()) { ran = true } } catch {}
                }
            }
            try require(!ran && gate.snapshot.failed && !gate.snapshot.releaseCallbackCompleted,
                "Release published after caught reentry")
        }
        try test("caught duplicate release invalidates release completion") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            var nested = false
            try rejected {
                try gate.withModelRelease {
                    do { try gate.withModelRelease { nested = true } } catch {}
                }
            }
            try require(!nested && !gate.snapshot.releaseCallbackCompleted && gate.snapshot.failed,
                "Nested release published success")
        }
        try test("completed release never runs another release or request body") {
            let gate = try QwenLayerStageResidentLifecycle(maximumRequests: 1)
            var bodies = 0
            try gate.withModelRelease { bodies += 1 }
            try rejected { try gate.withModelRelease { bodies += 1 } }
            try rejected { try gate.withRequest(identity: identity()) { bodies += 1 } }
            try require(bodies == 1 && gate.snapshot.releaseCallbackCompleted && gate.snapshot.failed,
                "Terminal owner was reused or prior release fact was lost")
        }
        try test("implicit ARC model destruction is not an explicit release receipt") {
            let ledger = ResidentFixtureLedger()
            var owner: ResidentFixtureOwner? = try .init(maximumRequests: 1, ledger: ledger)
            let before = owner!.snapshot
            owner = nil
            try require(ledger.observedModel == nil && !before.releaseCallbackCompleted,
                "ARC deinit was relabeled as verified cohort shutdown")
        }
        try test("concurrent request and release contenders refuse with four joined threads") {
            overlap = try checkResidentLifecycleOverlap()
            try require(overlap?.joinedThreads == 4, "Overlap fixture did not join all four threads")
        }

        struct Report: Encodable {
            let kind = "qwen_layer_stage_resident_lifecycle_cpu_check"
            let testsPassed: Int
            let cases: [String]
            let overlap: ResidentLifecycleOverlapResult?
            let nativeExecution = false
            let providerChanges = false
            let modelReuseQualified = false
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(Report(testsPassed: passed.count, cases: passed,
            overlap: overlap)), as: UTF8.self))
    }
}
