import Foundation

private typealias Operation = BoundedControlResourceOperation
private enum Refusal: Error, Equatable { case entry, exit, native, deadline }
private func require(_ value: @autoclosure () -> Bool) { precondition(value(), "Control operation invariant") }
private func refuses<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected refusal") }
    catch let value as E { require(value == expected) }
    catch { preconditionFailure("Wrong failure: \(error)") }
}
private func copiedData() -> Data {
    let input = Data([4, 3, 2, 1])
    return input.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
}

/// The actual helper runs actual Foundation Data allocations/copies. No MLX,
/// fake Collective, native completion stub or copied helper implementation.
@main private struct ControlOperationChecks {
    static func main() throws {
        var gates = 0, faults = 0, allocations = 0
        let sending = Operation()
        try sending.send(resourceCheck: { gates += 1 }, faultCheck: { faults += 1 }) { checkpoint in
            require(gates == 1)
            let data = copiedData(); allocations += 1
            try checkpoint.check(); try checkpoint.check()
            require(data == Data([4, 3, 2, 1]) && gates == 1)
        }
        require(gates == 2 && faults == 2 && allocations == 1)
        print("PASS send-entry-before-allocation-and-fresh-exit")

        var freshness = 1, observed: [Int] = []
        let received = try Operation().receive(resourceCheck: { observed.append(freshness) }, faultCheck: {}) { checkpoint in
            try checkpoint.check()
            let data = copiedData(); freshness = 2
            return data
        }
        require(received == Data([4, 3, 2, 1]) && observed == [1, 2])
        print("PASS receive-owned-copy-before-distinct-exit-observation")

        var allocated = false
        refuses(Refusal.entry) {
            try Operation().send(resourceCheck: { throw Refusal.entry }, faultCheck: {}) { _ in
                _ = copiedData(); allocated = true
            }
        }
        require(!allocated)
        print("PASS entry-refusal-prevents-data-allocation")

        var resourceCalls = 0, bodyReturned = false, published: Data?
        var retained: Operation.Checkpoint?
        refuses(Refusal.exit) {
            published = try Operation().receive(resourceCheck: {
                resourceCalls += 1; if resourceCalls == 2 { throw Refusal.exit }
            }, faultCheck: {}) { checkpoint in
                retained = checkpoint; let data = copiedData(); bodyReturned = true; return data
            }
        }
        require(bodyReturned && published == nil && resourceCalls == 2)
        refuses(Operation.Failure.closed) { try retained!.check() }
        print("PASS exit-refusal-after-copy-prevents-publication")

        resourceCalls = 0
        refuses(Refusal.native) {
            try Operation().send(resourceCheck: {
                resourceCalls += 1; if resourceCalls == 2 { throw Refusal.exit }
            }, faultCheck: { throw Refusal.native }) { checkpoint in try checkpoint.check() }
        }
        require(resourceCalls == 1)
        print("PASS inner-native-failure-keeps-primary-error")

        refuses(Refusal.deadline) {
            try Operation().send(resourceCheck: {}, faultCheck: { throw Refusal.deadline }) { checkpoint in
                try checkpoint.check(); preconditionFailure("Expired operation continued")
            }
        }
        print("PASS inner-deadline-refuses-before-continuation")

        let preCancelled = Operation(); preCancelled.cancel(); var entered = false
        refuses(Operation.Failure.reused) {
            try preCancelled.send(resourceCheck: { entered = true }, faultCheck: {}) { _ in
                preconditionFailure("Cancelled body")
            }
        }
        require(!entered)
        print("PASS prior-cancel-prevents-entry")

        let atEntry = Operation()
        refuses(Operation.Failure.cancelled) {
            try atEntry.send(resourceCheck: { atEntry.cancel() }, faultCheck: {}) { _ in
                preconditionFailure("Allocation after cancelled entry")
            }
        }
        print("PASS cancel-during-entry-prevents-allocation")

        let atFault = Operation()
        refuses(Operation.Failure.cancelled) {
            try atFault.send(resourceCheck: {}, faultCheck: { atFault.cancel() }) { checkpoint in
                try checkpoint.check(); preconditionFailure("Cancellation was ignored")
            }
        }
        print("PASS cancel-during-inner-check-refuses")

        let inBody = Operation()
        refuses(Operation.Failure.cancelled) {
            _ = try inBody.receive(resourceCheck: {}, faultCheck: {}) { _ in
                let data = copiedData(); inBody.cancel(); return data
            }
        }
        print("PASS cancel-before-body-return-prevents-publication")

        let atExit = Operation(); resourceCalls = 0
        refuses(Operation.Failure.cancelled) {
            _ = try atExit.receive(resourceCheck: {
                resourceCalls += 1; if resourceCalls == 2 { atExit.cancel() }
            }, faultCheck: {}) { _ in copiedData() }
        }
        require(resourceCalls == 2)
        print("PASS cancel-during-exit-prevents-publication")

        resourceCalls = 0
        refuses(Operation.Failure.reused) {
            try sending.send(resourceCheck: { resourceCalls += 1 }, faultCheck: {}) { _ in }
        }
        require(resourceCalls == 0)
        print("PASS completed-operation-cannot-replay")

        let nested = Operation()
        refuses(Operation.Failure.cancelled) {
            try nested.send(resourceCheck: {}, faultCheck: {}) { _ in
                refuses(Operation.Failure.reused) {
                    try nested.send(resourceCheck: {}, faultCheck: {}) { _ in }
                }
            }
        }
        print("PASS caught-reentry-poisons-original-operation")

        let recursion = Operation(); retained = nil
        refuses(Operation.Failure.reentered) {
            try recursion.send(resourceCheck: {}, faultCheck: { try retained!.check() }) { checkpoint in
                retained = checkpoint; try checkpoint.check()
            }
        }
        refuses(Operation.Failure.closed) { try retained!.check() }
        print("PASS recursive-check-poisons-and-closes")

        let caught = Operation()
        refuses(Operation.Failure.cancelled) {
            _ = try caught.receive(resourceCheck: {}, faultCheck: { throw Refusal.native }) { checkpoint in
                refuses(Refusal.native) { try checkpoint.check() }
                return copiedData()
            }
        }
        print("PASS caught-inner-failure-cannot-publish")

        retained = nil
        try Operation().send(resourceCheck: {}, faultCheck: {}) { checkpoint in retained = checkpoint }
        refuses(Operation.Failure.closed) { try retained!.check() }
        print("PASS escaped-checkpoint-has-no-live-callback")

        let atExitReplay = Operation(); resourceCalls = 0; retained = nil
        try atExitReplay.send(resourceCheck: {
            resourceCalls += 1
            if resourceCalls == 2 { refuses(Operation.Failure.closed) { try retained!.check() } }
        }, faultCheck: {}) { checkpoint in retained = checkpoint }
        require(resourceCalls == 2)
        print("PASS checkpoint-invalidated-before-exit-reader")
    }
}
