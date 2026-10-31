import Foundation
import MLX
import MLXLLM
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// The model-free parts of how a GLM tensor-parallel rank loads: the load
/// path switch, the phase line and the digest that compares load paths on the
/// real model. That the prepared pass builds the per-tensor loader's arrays
/// byte for byte is the SDK's `GLM5NextPreparedLoadTests`.
@Suite("GLM tensor-parallel load path")
struct GLM5NextTensorParallelLoadPathTests {
    typealias Path = GLM5NextTensorParallelLoadPath

    @Test func theProductReadsPreparedAndTheSwitchNamesOnlyKnownPaths() throws {
        #expect(try Path.resolved([:]) == .prepared)
        #expect(try Path.resolved([Path.environmentKey: "per-tensor"]) == .perTensor)
        #expect(try Path.resolved([Path.environmentKey: "prepared-uncached"]) == .preparedUncached)
        #expect(throws: ProbeError.self) { try Path.resolved([Path.environmentKey: "fast"]) }
        #expect(Path.prepared.verification == .withPreparedPayload)
        #expect(Path.preparedUncached.verification == .withPreparedPayload)
        #expect(Path.perTensor.verification == .beforeLoad)
    }

    @Test func phasesAreConsecutiveAndNamedInOrder() {
        var phases = GLM5NextTensorParallelLoadPhases(since: 1_000, startedUnixMilliseconds: 1_792_650_000_000)
        phases.mark("setup", now: 1_500)
        phases.mark("read", now: 4_000)
        phases.mark("build", now: 3_000)  // a clock that went back counts zero
        #expect(phases.line(rank: 1, path: .prepared)
            == "darkbloom-tensor-parallel-load-phases-v1 rank=1 path=prepared started_unix_ms=1792650000000"
                + " setup_ns=500 read_ns=2500 build_ns=0")
    }

    @Test func phasesNoteWorkBesideThemAfterThePhases() {
        var phases = GLM5NextTensorParallelLoadPhases(since: 0, startedUnixMilliseconds: 7)
        phases.mark("setup", now: 10)
        phases.note("metadata_thread", 25)
        phases.mark("link", now: 30)
        #expect(phases.line(rank: 0, path: .prepared)
            == "darkbloom-tensor-parallel-load-phases-v1 rank=0 path=prepared started_unix_ms=7"
                + " setup_ns=10 link_ns=20 metadata_thread_ns=25")
    }

    @Test func aBackgroundComputationIsJoinedWithItsValueOrItsError() throws {
        let value = GLM5NextTensorParallelBackground { () throws -> Int in usleep(20_000); return 42 }
        #expect(try value.join() == 42)
        #expect(value.finishedUptimeNanoseconds >= value.startedUptimeNanoseconds + 20_000_000)
        let failure = GLM5NextTensorParallelBackground { () throws -> Int in throw ProbeError("metadata") }
        #expect(throws: ProbeError.self) { try failure.join() }
    }

    @Test func digestsNameEveryArrayAndChangeWithAnyByte() throws {
        try Device.withDefaultDevice(.cpu) {
            let a = Linear(weight: MLXArray((0 ..< 12).map(Float.init), [3, 4]))
            let b = Linear(weight: MLXArray((0 ..< 12).map(Float.init), [3, 4]))
            let c = Linear(weight: MLXArray((0 ..< 12).map { Float($0 == 7 ? 70 : $0) }, [3, 4]))
            let digest = GLM5NextTensorParallelLoadDigest.self
            let entries = digest.entries([a])
            #expect(entries.map(\.key) == ["0.weight"] && entries[0].shape == [3, 4] && entries[0].dtype == "float32")
            #expect(digest.aggregate(digest.entries([a])) == digest.aggregate(digest.entries([b])))
            #expect(digest.aggregate(digest.entries([a])) != digest.aggregate(digest.entries([c])))
            // Order of modules is part of the key; order of lines is not part of the aggregate.
            #expect(digest.aggregate(entries.reversed()) == digest.aggregate(entries))
            #expect(digest.lines([a], rank: 0, path: .prepared, environment: [:]).isEmpty)
            let one = digest.lines([a, c], rank: 0, path: .perTensor, environment: [digest.environmentKey: "1"])
            #expect(one.count == 1 && one[0].hasPrefix(
                "darkbloom-tensor-parallel-load-digest-v1 rank=0 path=per-tensor arrays=2 elements=24 digest="))
            let all = digest.lines([a, c], rank: 0, path: .perTensor, environment: [digest.environmentKey: "tensors"])
            #expect(all.count == 3 && all[1].hasPrefix("darkbloom-tensor-parallel-load-tensor-v1 rank=0 0.weight 3x4 float32 "))
        }
    }
}
