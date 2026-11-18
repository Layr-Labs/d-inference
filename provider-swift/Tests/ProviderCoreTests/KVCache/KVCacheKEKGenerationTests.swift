import Foundation
import Testing
@testable import ProviderCore

/// The SSD cache key entry of this release is a new generation; earlier
/// generations are deleted before it is used.
@Suite(.serialized) struct KVCacheKEKGenerationTests {
    @Test func currentGenerationIsNotARetiredOne() {
        #expect(!KeychainWrappedKEKStorage.retiredServices.isEmpty)
        #expect(!KeychainWrappedKEKStorage.retiredServices.contains(KeychainWrappedKEKStorage.defaultService))
        #expect(KeychainWrappedKEKStorage.retiredServices.allSatisfy {
            $0.hasPrefix(BuildEnvironment.current.keychainServicePrefix + ".kv.kek.")
        })
    }

    @Test func retirementDeletesEveryEarlierGenerationAndNeverTheCurrentOne() {
        let deleted = Deleted()
        KeychainWrappedKEKStorage.retireEarlierGenerations { deleted.append($0) }
        // Once per process: a second call does nothing after a full success.
        KeychainWrappedKEKStorage.retireEarlierGenerations { deleted.append($0) }
        let calls = deleted.services
        #expect(Set(calls).isSubset(of: Set(KeychainWrappedKEKStorage.retiredServices)))
        #expect(!calls.contains(KeychainWrappedKEKStorage.defaultService))
        #expect(calls.count <= KeychainWrappedKEKStorage.retiredServices.count)
    }

    private final class Deleted: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func append(_ service: String) { lock.withLock { calls.append(service) } }
        var services: [String] { lock.withLock { calls } }
    }
}
