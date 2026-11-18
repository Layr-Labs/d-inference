import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import ProviderCore

// A stopping leader member (an app update's restart is one such stop) whose
// loop serves a committed start: the real member session and owner process
// (the CPU fixture child), the loop as the session's serving host, a scripted
// pair engine in the published slot, and the mock coordinator. Control flow
// and ownership only, never a pair, mesh or model.

/// What one callback saw, read later by the test.
private final class StopObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: String?
    func set(_ value: String) { lock.withLock { if seen == nil { seen = value } } }
    var value: String? { lock.withLock { seen } }
}

private struct StoppingLeader {
    let fixture: NativePairMemberFixture
    let loop: ProviderLoop
    let peer: MemberFixturePeer
    let builder: ScriptedPairBuilder

    static func make() async throws -> StoppingLeader {
        let fixture = try NativePairMemberFixture(lifetimeSeconds: 40, preparationSeconds: 20)
        let signer = MemberFixtureSigner()
        let loop = try ProviderLoop(
            config: .init(coordinatorURL: "ws://127.0.0.1:9/ws", hardware: memberFixtureHardware(),
                models: [.init(id: "fixture-model", modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(provider: .init(name: "cluster-member-stop", autoUpdate: false), backend: .init(),
                    coordinator: .init(url: "ws://127.0.0.1:9/ws", heartbeatIntervalSecs: 1)),
                executionRole: .clusterMember),
            attestationSigner: signer)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-member-stop-\(UUID().uuidString).json"))
        try await loop.prepareClusterMemberControlForTesting()
        try await loop.installNativePairMember(fixture.installations[0])
        let builder = ScriptedPairBuilder()
        let context = try ClusterPairServingContext(publicModelID: "fixture-model", modelType: "qwen3_5",
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99], profile: distributedTestProfile(),
            artifactBytes: 1 << 30, makeOwner: { try builder.make($0) })
        try await loop.installClusterPairServing(context)
        let control = try #require(await loop.nativePairMemberControl)
        return .init(fixture: fixture, loop: loop, peer: MemberFixturePeer(control: control, signer: signer), builder: builder)
    }

    /// Prepares, commits and launches the session's owner, then waits until
    /// the loop published the start's slot.
    func serveOneStart() async throws {
        try await peer.connect()
        try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
        _ = try await peer.wait("native_pair_prepared")
        try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
        _ = try await peer.wait("native_pair_hello")
        let epoch = fixture.starts[0].common.epoch
        #expect(await clusterPairWait { await loop.clusterPairServingSnapshot.slotEpoch == epoch })
    }
}

@Suite("A stopping cluster member releases its pair session", .serialized, .timeLimit(.minutes(2)))
struct ClusterMemberStopReleaseTests {
    /// The stop ends the session first, as a coordinator's cancel does: the
    /// session fences its owner and retires its slot, and the pair engine shuts
    /// its owner down only after the session stopped. The stop returns once the
    /// release receipt was sent, and no cancel frame goes out.
    @Test func aStoppingLeaderEndsItsSessionFirstAndSendsTheReceiptBeforeItReturns() async throws {
        let leader = try await StoppingLeader.make()
        do {
            try await leader.serveOneStart()
            let owner = try #require(leader.builder.built.first)
            let control = leader.peer.control
            let atEngineShutdown = StopObservation()
            owner.onShutdown = { atEngineShutdown.set(control.status) }
            await leader.loop.releaseClusterMemberSessionBeforeClose()
            // The receipt was written before the stop returned; the mock reads it a moment later.
            #expect(["idle", "released"].contains(control.status))
            let receipt = try await leader.peer.wait("native_pair_owner_released")
            var expected = Data([68, 66, 78, 82, 1])
            expected.append(contentsOf: SHA256.hash(data: leader.fixture.starts[0].canonicalBytes))
            expected.append(contentsOf: [1, 1, 1])
            #expect(Data(base64Encoded: receipt.payload) == expected)
            #expect(leader.peer.mock.snapshot().nativePairs.map(\.type)
                == ["native_pair_prepared", "native_pair_hello", "native_pair_owner_released"])
            #expect(owner.shutdownCount == 1)
            // A slot retired first would shut the owner down while the session still ran ("committed").
            #expect(atEngineShutdown.value != nil && atEngineShutdown.value != "committed")
            #expect(await leader.loop.clusterPairServingSnapshot.slotEpoch == nil)
            try leader.fixture.requireRetired(0, confirmed: false)
            await leader.peer.close()
        } catch { await leader.peer.close(); throw error }
    }

    /// A receipt that cannot go out (its signature does not return) does not
    /// hold the stop: it returns at its bound with no receipt and no cancel
    /// sent, and the slot is retired all the same.
    @Test func aStoppingLeaderReturnsAtTheBoundWhenItsReceiptCannotGoOut() async throws {
        let leader = try await StoppingLeader.make()
        await leader.loop.setMemberSessionReleaseTimeoutForTesting(0.5)
        let signer = leader.peer.signer
        do {
            try await leader.serveOneStart()
            // The next signature is the receipt's: it blocks until resumed.
            signer.pause(onCall: signer.callCount + 1)
            let began = ContinuousClock.now
            await leader.loop.releaseClusterMemberSessionBeforeClose()
            let took = ContinuousClock.now - began
            #expect(took >= .milliseconds(450) && took < .seconds(5))
            #expect(leader.peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_hello"])
            #expect(await leader.loop.clusterPairServingSnapshot.slotEpoch == nil)
            #expect(leader.builder.built.first?.shutdownCount == 1)
            signer.resume()
            await leader.peer.close()
        } catch { signer.resume(); await leader.peer.close(); throw error }
    }
}
