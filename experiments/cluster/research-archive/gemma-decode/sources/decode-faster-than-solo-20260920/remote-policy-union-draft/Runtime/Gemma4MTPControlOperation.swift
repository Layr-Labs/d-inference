import Foundation
import MLX

/// One synchronous fixed host-control transfer at a time. The original full
/// resource closure runs independently before allocation and after completion.
/// Nothing stores either borrowed closure or its native error context.
final class Gemma4MTPControlOperation {
    let counters = Gemma4MTPControlCounters()
    private let metrics: Gemma4BenchmarkGuardMetrics
    init(metrics: Gemma4BenchmarkGuardMetrics) { self.metrics = metrics }

    func send(resourceCheck: () throws -> Void, lifetimeCheck: () throws -> Void,
              body: (BoundedControlResourceOperation.Checkpoint) throws -> Void) throws {
        try counters.begin(.send)
        do {
            try MLX.withError { native -> Void in
                func resource() throws {
                    try native.check(); try resourceCheck(); try native.check()
                    try counters.resourceChecked()
                }
                func fault() throws {
                    try native.check(); try lifetimeCheck(); try native.check()
                    try counters.innerChecked()
                }
                let operation = BoundedControlResourceOperation()
                try withExtendedLifetime(operation) {
                    try operation.send(resourceCheck:resource,faultCheck:fault) { checkpoint in
                        try metrics.measure(.wireSendCompleted) { try body(checkpoint) }
                    }
                }
            }
            try counters.complete()
        } catch { counters.poison(); throw error }
    }
    func receive(resourceCheck: () throws -> Void, lifetimeCheck: () throws -> Void,
                 body: (BoundedControlResourceOperation.Checkpoint) throws -> Data) throws -> Data {
        try counters.begin(.receive)
        do {
            let result: Data = try MLX.withError { native -> Data in
                func resource() throws {
                    try native.check(); try resourceCheck(); try native.check()
                    try counters.resourceChecked()
                }
                func fault() throws {
                    try native.check(); try lifetimeCheck(); try native.check()
                    try counters.innerChecked()
                }
                let operation = BoundedControlResourceOperation()
                return try withExtendedLifetime(operation) {
                    try operation.receive(resourceCheck:resource,faultCheck:fault) { checkpoint in
                        try metrics.measure(.wireReceiveCompleted) { try body(checkpoint) }
                    }
                }
            }
            try counters.complete()
            return result
        } catch { counters.poison(); throw error }
    }
}
