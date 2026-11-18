import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// The SSD cache key entry of this release is a new generation; earlier
/// generations are deleted at every load of the production key, never read.
@Suite struct KVCacheKEKGenerationTests {
    @Test func currentGenerationIsNotARetiredOne() {
        #expect(!KeychainWrappedKEKStorage.retiredServices.isEmpty)
        #expect(!KeychainWrappedKEKStorage.retiredServices.contains(KeychainWrappedKEKStorage.defaultService))
        #expect(KeychainWrappedKEKStorage.retiredServices.allSatisfy {
            $0.hasPrefix(BuildEnvironment.current.keychainServicePrefix + ".kv.kek.")
        })
    }

    @Test func retirementDeletesExactlyTheEarlierGenerationsAtEveryLoad() {
        let deleted = Recorder()
        #expect(KeychainWrappedKEKStorage.retireEarlierGenerations { deleted.append($0) }.isEmpty)
        // Not once per process: an entry created again in between is removed by the next load.
        #expect(KeychainWrappedKEKStorage.retireEarlierGenerations { deleted.append($0) }.isEmpty)
        #expect(deleted.events == KeychainWrappedKEKStorage.retiredServices + KeychainWrappedKEKStorage.retiredServices)
        #expect(!deleted.events.contains(KeychainWrappedKEKStorage.defaultService))
    }

    @Test func aFailedDeletionIsReportedAndRetriedAtTheNextLoad() {
        struct Locked: Error {}
        let attempts = Recorder()
        let failed = KeychainWrappedKEKStorage.retireEarlierGenerations { attempts.append($0); throw Locked() }
        #expect(failed == KeychainWrappedKEKStorage.retiredServices)
        #expect(KeychainWrappedKEKStorage.retireEarlierGenerations { attempts.append($0) }.isEmpty)
        #expect(attempts.events == KeychainWrappedKEKStorage.retiredServices + KeychainWrappedKEKStorage.retiredServices)
    }

    @Test func theProductionKeyRetiresEarlierGenerationsBeforeItIsOpened() async throws {
        let order = Recorder()
        let material = try await SSDCacheKeyMaterial.load(
            environment: [:],
            persistentLoader: { namespace in
                order.append(namespace == nil ? "open production key" : "open test key")
                return SymmetricKey(size: .bits256)
            },
            retireEarlierGenerations: { order.append("retire") })
        #expect(!material.ephemeral)
        #expect(order.events == ["retire", "open production key"])
    }

    @Test func aFailedRetirementDoesNotStopTheCurrentKey() async throws {
        let order = Recorder()
        let material = try await SSDCacheKeyMaterial.load(
            environment: [:],
            persistentLoader: { _ in order.append("open"); return SymmetricKey(size: .bits256) },
            retireEarlierGenerations: {
                struct Locked: Error {}
                KeychainWrappedKEKStorage.retireEarlierGenerations { _ in order.append("delete failed"); throw Locked() }
            })
        #expect(!material.ephemeral)
        #expect(order.events == KeychainWrappedKEKStorage.retiredServices.map { _ in "delete failed" } + ["open"])
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func append(_ event: String) { lock.withLock { recorded.append(event) } }
        var events: [String] { lock.withLock { recorded } }
    }
}
