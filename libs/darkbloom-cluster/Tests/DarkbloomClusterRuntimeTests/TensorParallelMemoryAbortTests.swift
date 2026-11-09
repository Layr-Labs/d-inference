import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// D6 in tensor parallel, and the dev-only fault that proves it on real Macs.
@Suite("A tensor-parallel rank's memory refusal ends that request alone", .serialized)
struct TensorParallelMemoryAbortTests {
    private typealias Rule = QwenTensorParallelStopRule

    /// Both ranks leave a request after the same step and then agree how it
    /// ended: rank 0's count, finish and whether its owner asked to stop, and
    /// each rank's memory stop, each in its own words of one exchange. A local
    /// stop that ended it and a rank that stopped for memory make it a memory
    /// abort naming that rank; a request that ended anyway (its stop token,
    /// its length, its owner's stop) ends as it would have.
    @Test func theEndAgreementNamesAMemoryStopOnlyWhenALocalStopEndedTheRequest() throws {
        func agree(_ zero: (count: Int, finish: Rule.Finish, client: Bool, memory: Bool), memory1: Bool) throws -> Rule.End {
            let a = Rule.endWords(rank: 0, count: zero.count, finish: zero.finish, clientStopped: zero.client,
                                  stoppedForMemory: zero.memory)
            let b = Rule.endWords(rank: 1, count: 9, finish: .clientStop, clientStopped: false, stoppedForMemory: memory1)
            #expect(a.count == b.count)
            return try Rule.readEnd(zip(a, b).map(+))
        }
        // Rank 1's memory stopped it; rank 0 only followed the agreed stop slot.
        var end = try agree((5, .clientStop, false, false), memory1: true)
        #expect(end.rank0Count == 5 && end.rank0Finish == .clientStop && end.abort == .init(reason: .memory, rank: 1))
        // Rank 0's own memory stopped it.
        end = try agree((5, .clientStop, false, true), memory1: false)
        #expect(end.abort == .init(reason: .memory, rank: 0))
        // Both at once: rank 0 is named.
        #expect(try agree((5, .clientStop, false, true), memory1: true).abort == .init(reason: .memory, rank: 0))
        // The owner's stop, a stop token, the length: no abort, whatever the bits.
        #expect(try agree((5, .clientStop, true, false), memory1: true).abort == nil)
        #expect(try agree((5, .eos, false, false), memory1: true).abort == nil)
        #expect(try agree((5, .length, false, true), memory1: false).abort == nil)
        // A cancel or deadline (a local stop for anything but memory): no abort, the old failure.
        #expect(try agree((5, .clientStop, false, false), memory1: false).abort == nil)
        // Malformed words are refused.
        #expect(throws: ProbeError.self) { try Rule.readEnd([5, 3, 0, 2, 0]) }
        #expect(throws: ProbeError.self) { try Rule.readEnd([5, 9, 0, 0, 0]) }
        #expect(throws: ProbeError.self) { try Rule.readEnd([5, 3]) }
    }

    private static func installs() throws -> (production: URL, dev: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("memory-fault-\(UUID().uuidString)")
        let production = home.appendingPathComponent(".darkbloom"), dev = home.appendingPathComponent(".darkbloom-dev")
        for install in [production, dev] {
            let setup = install.appendingPathComponent("cluster-setup")
            try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
            try Data("3\n".utf8).write(to: install.appendingPathComponent(ClusterMemoryFault.switchPath))
        }
        return (production, dev)
    }

    /// The fault reads its switch only in a dev or DevNet install
    /// (`~/.darkbloom-dev`): a production install's file is never read nor
    /// consumed, and the gate never refuses there. In a dev install it is
    /// consumed when the next request starts (one-shot), and from that
    /// request's third check on its gate refuses; the request's end disarms it.
    @Test func theMemoryFaultIsInertInAProductionInstallAndOneShotInADevOne() throws {
        let (production, dev) = try Self.installs()
        defer { try? FileManager.default.removeItem(at: production.deletingLastPathComponent()) }
        let fault = ClusterMemoryFault()
        #expect(fault.arm(requestID: UUID(), installDirectory: production) == nil)
        #expect(FileManager.default.fileExists(atPath: production.appendingPathComponent(ClusterMemoryFault.switchPath).path))
        for _ in 0..<5 { try fault.refuseIfDue() }

        let request = UUID()
        #expect(fault.arm(requestID: request, installDirectory: dev) == 3)
        #expect(!FileManager.default.fileExists(atPath: dev.appendingPathComponent(ClusterMemoryFault.switchPath).path))
        try fault.refuseIfDue(); try fault.refuseIfDue()
        #expect(throws: (any Error).self) { try fault.refuseIfDue() }
        #expect(throws: (any Error).self) { try fault.refuseIfDue() }
        // Another request's end leaves it armed; its own end disarms it.
        fault.disarm(requestID: UUID())
        #expect(throws: (any Error).self) { try fault.refuseIfDue() }
        fault.disarm(requestID: request)
        try fault.refuseIfDue()
        // One-shot: the next request finds no switch.
        #expect(fault.arm(requestID: UUID(), installDirectory: dev) == nil)
        try fault.refuseIfDue()
        // A malformed switch is consumed and arms nothing.
        try Data("soon".utf8).write(to: dev.appendingPathComponent(ClusterMemoryFault.switchPath))
        #expect(fault.arm(requestID: UUID(), installDirectory: dev) == nil)
        #expect(!FileManager.default.fileExists(atPath: dev.appendingPathComponent(ClusterMemoryFault.switchPath).path))
    }

    /// The fault takes a real refusal's path: inside each live gate, where the
    /// gate's own refusal is thrown, so the gate throws the typed memory
    /// refusal that the stop latch, the stop slot and the batch read.
    @Test func anArmedFaultRefusesThroughTheGatesOwnThrow() throws {
        let (production, dev) = try Self.installs()
        defer { try? FileManager.default.removeItem(at: production.deletingLastPathComponent()) }
        let fault = ClusterMemoryFault()
        let request = UUID()
        #expect(fault.arm(requestID: request, installDirectory: dev) == 3)
        let allowance = QwenResidentRequestAllowance(stateBytes: 1, fusionBytes: 0, reservedBytes: 1)
        try ClusterMemoryFault.$override.withValue(fault) {
            var refusals: [Bool] = []
            for _ in 0..<4 {
                do { try ClusterLiveMemory.requireTensorParallel(bytes: 0, family: "fixture"); refusals.append(false) }
                catch is QwenResidentMemoryRefusal { refusals.append(true) }
            }
            // Checks one and two pass (a real gate may refuse them too on a busy Mac: only the fault's are pinned).
            #expect(refusals.suffix(2) == [true, true])
            do { try allowance.requireContinuing(grownBytes: 0); Issue.record("the continuing gate admitted an armed fault") }
            catch is QwenResidentMemoryRefusal {}
        }
        fault.disarm(requestID: request)
    }
}
