import Foundation

@testable import DarkbloomFanCore

final class FakeSMCBackend: SMCBackend, @unchecked Sendable {
    enum Operation: Equatable {
        case keyInfo(SMCKey)
        case read(SMCKey)
        case write(SMCKey, [UInt8])
    }

    enum WriteBehavior {
        case succeed
        case ignore
        case replace([UInt8])
        case failBefore(SMCError)
        case failAfter(SMCError)
    }

    struct Entry {
        var info: SMCKeyInfo
        var bytes: [UInt8]
    }

    private let lock = NSLock()
    private var entries: [SMCKey: Entry] = [:]
    private var writeBehaviors: [SMCKey: [WriteBehavior]] = [:]
    private var recordedOperations: [Operation] = []
    private var writeHook: (@Sendable (SMCKey, [UInt8]) -> Void)?
    private var readHook: (@Sendable (SMCKey, Int) -> Void)?
    private var readCounts: [SMCKey: Int] = [:]

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    func resetOperations() {
        lock.withLock { recordedOperations.removeAll() }
    }

    func installWriteHook(_ hook: (@Sendable (SMCKey, [UInt8]) -> Void)?) {
        lock.withLock { writeHook = hook }
    }

    func installReadHook(_ hook: (@Sendable (SMCKey, Int) -> Void)?) {
        lock.withLock {
            readHook = hook
            readCounts.removeAll()
        }
    }

    func queue(_ behaviors: [WriteBehavior], for key: SMCKey) {
        lock.withLock { writeBehaviors[key, default: []].append(contentsOf: behaviors) }
    }

    func remove(_ key: SMCKey) {
        _ = lock.withLock { entries.removeValue(forKey: key) }
    }

    func setUI8(_ key: SMCKey, _ value: UInt8) {
        set(
            key,
            info: SMCKeyInfo(dataSize: 1, dataType: try! SMCDataType("ui8 ")),
            bytes: [value]
        )
    }

    func setFloat(_ key: SMCKey, _ value: Double) {
        set(
            key,
            info: SMCKeyInfo(dataSize: 4, dataType: try! SMCDataType("flt ")),
            bytes: try! SMCValue.float32Bytes(value, key: key)
        )
    }

    func setFixed(_ key: SMCKey, type: String, raw: UInt16) {
        set(
            key,
            info: SMCKeyInfo(dataSize: 2, dataType: try! SMCDataType(type)),
            bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)]
        )
    }

    func set(_ key: SMCKey, info: SMCKeyInfo, bytes: [UInt8]) {
        precondition(info.dataSize == bytes.count)
        lock.withLock { entries[key] = Entry(info: info, bytes: bytes) }
    }

    func uint8(_ key: SMCKey) throws -> UInt8 {
        try read(key).uint8()
    }

    func float(_ key: SMCKey) throws -> Double {
        try read(key).float32()
    }

    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        try lock.withLock {
            recordedOperations.append(.keyInfo(key))
            guard let entry = entries[key] else { throw SMCError.keyNotFound(key) }
            return entry.info
        }
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        let snapshot: (Entry, Int, (@Sendable (SMCKey, Int) -> Void)?) = try lock.withLock {
            recordedOperations.append(.read(key))
            guard let entry = entries[key] else { throw SMCError.keyNotFound(key) }
            let count = readCounts[key, default: 0] + 1
            readCounts[key] = count
            return (entry, count, readHook)
        }
        snapshot.2?(key, snapshot.1)
        return try SMCValue(
            key: key,
            info: snapshot.0.info,
            bytes: snapshot.0.bytes
        )
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws {
        let snapshot: (Entry, WriteBehavior, (@Sendable (SMCKey, [UInt8]) -> Void)?) =
            try lock.withLock {
                recordedOperations.append(.write(key, bytes))
                guard let entry = entries[key] else { throw SMCError.keyNotFound(key) }
                guard entry.info.dataSize == bytes.count else {
                    throw SMCError.dataLengthMismatch(
                        key: key,
                        expected: entry.info.dataSize,
                        actual: bytes.count
                    )
                }
                let behavior: WriteBehavior
                if var queued = writeBehaviors[key], !queued.isEmpty {
                    behavior = queued.removeFirst()
                    writeBehaviors[key] = queued
                } else {
                    behavior = .succeed
                }
                return (entry, behavior, writeHook)
            }

        snapshot.2?(key, bytes)
        switch snapshot.1 {
        case .succeed:
            lock.withLock { entries[key]?.bytes = bytes }
        case .ignore:
            break
        case .replace(let replacement):
            lock.withLock { entries[key]?.bytes = replacement }
        case .failBefore(let error):
            throw error
        case .failAfter(let error):
            lock.withLock { entries[key]?.bytes = bytes }
            throw error
        }
    }
}

func makeFanBackend(
    fanCount: Int = 2,
    lowercaseModeKeys: Bool = false,
    includeFtst: Bool = true,
    chipFamily: FanChipFamily = .m4
) -> FakeSMCBackend {
    let backend = FakeSMCBackend()
    backend.setUI8("FNum", UInt8(fanCount))
    for index in 0..<fanCount {
        backend.setFloat(try! SMCKey("F\(index)Ac"), 1_500 + Double(index * 100))
        backend.setFloat(try! SMCKey("F\(index)Mn"), 1_200 + Double(index * 100))
        backend.setFloat(try! SMCKey("F\(index)Mx"), 5_000 + Double(index * 500))
        backend.setFloat(try! SMCKey("F\(index)Tg"), 1_400 + Double(index * 100))
        let suffix = lowercaseModeKeys ? "md" : "Md"
        backend.setUI8(try! SMCKey("F\(index)\(suffix)"), 0)
    }
    if includeFtst {
        backend.setUI8("Ftst", 0)
    }
    for key in GPUTemperatureCatalog.keys(for: chipFamily) {
        backend.setFloat(key, 50)
    }
    return backend
}
