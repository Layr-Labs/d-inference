import Foundation
import Testing

@testable import ProviderCore

/// One model root whose epoch record the tests make unreadable, replace or
/// remove through the filesystem, exactly as a provider would observe it.
private final class EpochRecordFixture: @unchecked Sendable {
    let root: URL
    let record: URL
    let binding = EpochRecordFixture.binding(contract: "contract")

    init() throws {
        root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-recovery-\(UUID().uuidString)", isDirectory: true)
        record = root.appendingPathComponent("cache-epoch.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func binding(contract: String) -> SSDCacheEpochStore.Binding {
        SSDCacheEpochStore.Binding(
            modelId: "model", modelAggregateHash: "weights", promptContractId: contract,
            blockHashVersion: "dbk3", blockSize: 256, layoutEpoch: "layout", keyFingerprint: "key")
    }

    func open() throws -> SSDCacheEpochStore {
        try SSDCacheEpochStore(root: root, binding: binding)
    }

    /// The record stays a regular file but cannot be opened: chmod stands in
    /// for an `openat` failure, the class of read failure that says nothing
    /// about the record's content (EACCES here; EIO or EBUSY in production).
    func denyRecordReads() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: record.path)
    }

    func allowRecordReads() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    }

    func recordBytes() throws -> Data {
        try Data(contentsOf: record)
    }

    /// Renamed into place like the store's own writes, which works whatever
    /// the permissions of the record being replaced.
    func replaceRecord(with bytes: Data) throws {
        let staged = root.appendingPathComponent("staged-record-\(UUID().uuidString)")
        try bytes.write(to: staged)
        guard rename(staged.path, record.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Starts from bytes read earlier, because the live record may be unreadable.
    func replaceRecord(editing original: Data, _ change: (inout [String: Any]) -> Void) throws {
        var fields = try #require(
            try JSONSerialization.jsonObject(with: original) as? [String: Any])
        change(&fields)
        try replaceRecord(with: JSONSerialization.data(withJSONObject: fields))
    }

    func persistedEpoch() throws -> String {
        let fields = try #require(
            try JSONSerialization.jsonObject(with: recordBytes()) as? [String: Any])
        return try #require(fields["epoch"] as? String)
    }
}

private func retires(_ store: SSDCacheEpochStore) -> Bool {
    store.performOwnedRetirement { true } ?? false
}

/// Results gathered from concurrent callers of one store.
private final class ConcurrentOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var advertised: [String?] = []
    private var issued: [UInt64?] = []
    private var retired: [Bool] = []

    func record(advertised epoch: String?, issued sequence: UInt64?, retired ran: Bool) {
        lock.withLock {
            advertised.append(epoch)
            issued.append(sequence)
            retired.append(ran)
        }
    }

    var advertisedEpochs: [String?] { lock.withLock { advertised } }
    var issuedSequences: [UInt64] { lock.withLock { issued.compactMap { $0 } } }
    var refusedSequences: Int { lock.withLock { issued.count(where: { $0 == nil }) } }
    var retirements: [Bool] { lock.withLock { retired } }
}

/// File permissions do not stop the superuser, so a denied read would succeed.
@Suite("SSD cache epoch ownership across record read failures", .enabled(if: getuid() != 0))
struct SSDCacheEpochStoreRecoveryTests {
    enum ForeignRecord: CaseIterable {
        case otherEpoch
        case otherBinding
        case otherSchema
    }

    enum MalformedRecord: CaseIterable {
        case notJSON
        case truncated
        case empty
        case oversized
    }

    enum NonRegularRecord: CaseIterable {
        case symlinkToTheRecord
        case directory
    }

    // Reproduction of the defect: the original code treated any failed record
    // read as a replaced record and disowned the instance for good.
    @Test("a failed record read refuses the retirement but does not disown the instance")
    func transientReadFailureDoesNotDisown() throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)

        try f.denyRecordReads()
        var bodyRuns = 0
        let refused: Void? = store.performOwnedRetirement { bodyRuns += 1 }
        #expect(refused == nil)
        #expect(bodyRuns == 0, "a retirement whose record read failed must not run")
        #expect(store.current == epoch, "a failed read is not an invalidation")

        try f.allowRecordReads()
        let retired: Void? = store.performOwnedRetirement { bodyRuns += 1 }
        #expect(retired != nil, "the next retirement pass rereads and proceeds")
        #expect(bodyRuns == 1)
        #expect(store.current == epoch)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 1)
    }

    @Test("a failed record read refuses a rotation without disowning or touching the record")
    func transientReadFailureDoesNotDisownRotation() throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)

        try f.denyRecordReads()
        #expect(store.rotate() == nil)
        #expect(store.current == epoch)

        try f.allowRecordReads()
        #expect(try f.persistedEpoch() == epoch, "a refused rotation leaves the record alone")
        let rotated = try #require(store.rotate())
        #expect(rotated != epoch)
        #expect(store.current == rotated)
        #expect(try f.persistedEpoch() == rotated)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
        #expect(store.takeNextSequence(expectedEpoch: rotated) == 1)
    }

    @Test("repeated failures keep ownership, issue nothing and change nothing on disk")
    func repeatedFailuresKeepOwnership() throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 1)
        let persisted = try f.recordBytes()

        try f.denyRecordReads()
        for _ in 0 ..< 5 {
            #expect(!retires(store))
            #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
            #expect(store.rotate() == nil)
            #expect(store.current == epoch)
        }
        try f.allowRecordReads()

        #expect(try f.recordBytes() == persisted, "no identity or sequence is minted while unreadable")
        #expect(store.current == epoch)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == 2)
        #expect(retires(store))
    }

    @Test("a removed record disowns the instance, before or after a failed read")
    func removedRecordDisowns() throws {
        for failsFirst in [false, true] {
            let f = try EpochRecordFixture()
            let store = try f.open()
            let epoch = try #require(store.current)
            let original = try f.recordBytes()

            if failsFirst {
                try f.denyRecordReads()
                #expect(!retires(store))
                #expect(store.current == epoch)
            }
            try FileManager.default.removeItem(at: f.record)

            #expect(!retires(store))
            #expect(store.current == nil)
            #expect(!FileManager.default.fileExists(atPath: f.record.path), "the record is not recreated")

            // Disowned is final: the instance does not come back even if the
            // very record it used to own reappears.
            try f.replaceRecord(with: original)
            #expect(store.current == nil)
            #expect(!retires(store))
            #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
            #expect(store.rotate() == nil)
        }
    }

    @Test("a record that names another epoch, binding or schema disowns the instance", arguments: ForeignRecord.allCases)
    func changedRecordDisowns(_ foreign: ForeignRecord) throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        let original = try f.recordBytes()

        try f.replaceRecord(editing: original) { fields in
            switch foreign {
            case .otherEpoch:
                fields["epoch"] = UUID().uuidString.lowercased()
            case .otherBinding:
                var binding = fields["binding"] as? [String: Any] ?? [:]
                binding["promptContractId"] = "another-contract"
                fields["binding"] = binding
            case .otherSchema:
                fields["schema"] = "darkbloom.cache-epoch.invalidating.v1"
            }
        }

        #expect(!retires(store))
        #expect(store.current == nil)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)

        try f.replaceRecord(with: original)
        #expect(store.current == nil)
        #expect(!retires(store))
        #expect(store.rotate() == nil)
        #expect(try f.recordBytes() == original)
    }

    @Test("a record that changed while reads were failing disowns on the first successful read", arguments: ForeignRecord.allCases)
    func changedRecordAfterFailureDisowns(_ foreign: ForeignRecord) throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        let original = try f.recordBytes()

        try f.denyRecordReads()
        #expect(!retires(store))
        #expect(store.current == epoch)
        try f.replaceRecord(editing: original) { fields in
            switch foreign {
            case .otherEpoch:
                fields["epoch"] = UUID().uuidString.lowercased()
            case .otherBinding:
                var binding = fields["binding"] as? [String: Any] ?? [:]
                binding["promptContractId"] = "another-contract"
                fields["binding"] = binding
            case .otherSchema:
                fields["schema"] = "darkbloom.cache-epoch.invalidating.v1"
            }
        }

        #expect(!retires(store))
        #expect(store.current == nil)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
    }

    @Test("a record whose bytes are not a record disowns the instance", arguments: MalformedRecord.allCases)
    func malformedRecordDisowns(_ malformed: MalformedRecord) throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        let original = try f.recordBytes()

        let bytes: Data
        switch malformed {
        case .notJSON: bytes = Data("not json".utf8)
        case .truncated: bytes = original.prefix(original.count / 2)
        case .empty: bytes = Data()
        case .oversized: bytes = original + Data(repeating: 0x20, count: 64 * 1024 + 1 - original.count)
        }
        try f.replaceRecord(with: bytes)

        #expect(!retires(store))
        #expect(store.current == nil)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)

        try f.replaceRecord(with: original)
        #expect(store.current == nil)
        #expect(!retires(store))
    }

    @Test("a record path that is no longer a regular file disowns the instance", arguments: NonRegularRecord.allCases)
    func nonRegularRecordDisowns(_ replacement: NonRegularRecord) throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        let original = try f.recordBytes()
        let outside = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-recovery-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.removeItem(at: f.record)
        switch replacement {
        case .symlinkToTheRecord:
            // Even a link to a byte-identical record is never followed.
            try original.write(to: outside)
            try FileManager.default.createSymbolicLink(at: f.record, withDestinationURL: outside)
        case .directory:
            try FileManager.default.createDirectory(at: f.record, withIntermediateDirectories: false)
        }

        #expect(!retires(store))
        #expect(store.current == nil)
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
        #expect(store.rotate() == nil)

        // Disowned is final even once the exact record is back.
        try FileManager.default.removeItem(at: f.record)
        try f.replaceRecord(with: original)
        #expect(store.current == nil)
        #expect(!retires(store))
        #expect(store.takeNextSequence(expectedEpoch: epoch) == nil)
    }

    @Test("a second instance does not bring a disowned instance back")
    func secondInstanceDoesNotResurrectDisownedInstance() throws {
        let f = try EpochRecordFixture()
        let disowned = try f.open()
        let epoch = try #require(disowned.current)
        let original = try f.recordBytes()

        try f.replaceRecord(editing: original) { $0["epoch"] = UUID().uuidString.lowercased() }
        #expect(!retires(disowned))
        #expect(disowned.current == nil)

        // The exact record is back and a same-binding instance republishes
        // the same epoch for the root; the disowned instance stays out.
        try f.replaceRecord(with: original)
        let second = try f.open()
        #expect(second.current == epoch)
        #expect(disowned.current == nil)
        #expect(!retires(disowned))
        #expect(disowned.takeNextSequence(expectedEpoch: epoch) == nil)
        #expect(second.takeNextSequence(expectedEpoch: epoch) == 1)
    }

    @Test("concurrent callers keep the epoch through a failure and all proceed after it")
    func concurrentOperationsKeepOwnershipThenProceed() throws {
        let f = try EpochRecordFixture()
        let store = try f.open()
        let epoch = try #require(store.current)
        let callers = 8
        let roundsPerCaller = 12
        var issuedSoFar: UInt64 = 0

        func runCallers() -> ConcurrentOutcomes {
            let outcomes = ConcurrentOutcomes()
            DispatchQueue.concurrentPerform(iterations: callers) { _ in
                for _ in 0 ..< roundsPerCaller {
                    outcomes.record(
                        advertised: store.current,
                        issued: store.takeNextSequence(expectedEpoch: epoch),
                        retired: retires(store))
                }
            }
            return outcomes
        }

        for _ in 0 ..< 3 {
            try f.denyRecordReads()
            let failing = runCallers()
            #expect(failing.advertisedEpochs.allSatisfy { $0 == epoch })
            #expect(failing.issuedSequences.isEmpty)
            #expect(failing.retirements.allSatisfy { !$0 })

            try f.allowRecordReads()
            let recovered = runCallers()
            #expect(recovered.advertisedEpochs.allSatisfy { $0 == epoch })
            #expect(recovered.refusedSequences == 0)
            #expect(recovered.retirements.allSatisfy { $0 })
            let expected = (issuedSoFar + 1) ... (issuedSoFar + UInt64(callers * roundsPerCaller))
            #expect(recovered.issuedSequences.sorted() == Array(expected))
            issuedSoFar = expected.upperBound
        }
    }
}
