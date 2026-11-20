import CryptoKit
import Foundation

extension ClusterNativeAuthorizationCommon {
    static let domain = Data("darkbloom/native-authorization/common/v1\0".utf8)
    static let encodedCount = domain.count + 16 + 8 + 8 + 8 * 32 + 3 + 4 + 4 + 8 + 8
    public var canonicalBytes: Data {
        var bytes = Self.domain
        bytes.append(clusterRecordUUIDBytes(epoch))
        bytes.clusterAppendBigEndian(membershipGeneration); bytes.clusterAppendBigEndian(nativePolicyGeneration)
        for digest in [membershipTranscriptSHA256, approvedNativeBindingSHA256, planSHA256, artifactSHA256,
                       nativeRuntimeSHA256, capabilitySHA256, resourcePolicySHA256, profileSHA256] { bytes.append(digest) }
        // Closed suite, transport (JACCL P2P), and selected schedule.
        bytes.append(contentsOf: [1, 1, schedule.rawValue])
        bytes.clusterAppendBigEndian(UInt32(maximumTransportFrameBytes))
        bytes.append(limits.canonicalBytes)
        return bytes
    }
    init(cursor: inout NativeAuthorizationCursor) throws {
        try cursor.expect(Self.domain)
        let epoch = try cursor.uuid(), generation: UInt64 = try cursor.integer(), policy: UInt64 = try cursor.integer()
        var digests: [Data] = []
        for _ in 0..<8 { digests.append(try cursor.data(32)) }
        try cursor.expect(Data([1, 1]))
        guard let schedule = ClusterNativePrefillSchedule(rawValue: try cursor.byte()) else { throw ClusterNativeKeyError.invalidBinding }
        let frame: UInt32 = try cursor.integer(), plaintext: UInt32 = try cursor.integer()
        let records: UInt64 = try cursor.integer(), total: UInt64 = try cursor.integer()
        let limits = try ClusterRecordLimits(maximumPlaintextBytes: Int(plaintext),
            maximumRecordsPerDirection: records, maximumCumulativePlaintextBytesPerDirection: total)
        try self.init(epoch: epoch, membershipGeneration: generation, nativePolicyGeneration: policy,
            membershipTranscriptSHA256: digests[0], approvedNativeBindingSHA256: digests[1], planSHA256: digests[2],
            artifactSHA256: digests[3], nativeRuntimeSHA256: digests[4], capabilitySHA256: digests[5],
            resourcePolicySHA256: digests[6], profileSHA256: digests[7], schedule: schedule,
            maximumTransportFrameBytes: Int(frame), limits: limits)
    }
}

extension ClusterNativeAuthorizationStart {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x53, 1])
    static let encodedCount = prefix.count + ClusterNativeAuthorizationCommon.encodedCount + 1 + 3 * 16
    public var canonicalBytes: Data {
        var bytes = Self.prefix; bytes.append(common.canonicalBytes); bytes.append(UInt8(rank))
        for id in [ownerIncarnation, leaseID, launchID] { bytes.append(clusterRecordUUIDBytes(id)) }
        return bytes
    }
    public init(encoded: Data) throws {
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: Self.encodedCount)
        try cursor.expect(Self.prefix)
        let common = try ClusterNativeAuthorizationCommon(cursor: &cursor), rank = try cursor.byte()
        try self.init(common: common, rank: Int(rank), ownerIncarnation: cursor.uuid(), leaseID: cursor.uuid(), launchID: cursor.uuid())
        try cursor.finish()
    }
}

extension ClusterNativeKeyHello {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x48, 1])
    static let encodedCount = prefix.count + ClusterNativeAuthorizationStart.encodedCount + 32
    public var canonicalBytes: Data {
        var bytes = Self.prefix; bytes.append(start.canonicalBytes); bytes.append(publicKey); return bytes
    }
    public init(encoded: Data) throws {
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: Self.encodedCount)
        try cursor.expect(Self.prefix)
        let start = try ClusterNativeAuthorizationStart(encoded: cursor.data(ClusterNativeAuthorizationStart.encodedCount))
        try self.init(start: start, publicKey: cursor.data(32)); try cursor.finish()
    }
}

extension ClusterNativeKeyBinding {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x42, 1])
    public static let encodedCount = prefix.count + 2 * ClusterNativeKeyHello.encodedCount
    public var canonicalBytes: Data {
        var bytes = Self.prefix
        for hello in hellos { bytes.append(hello.canonicalBytes) }
        return bytes
    }
    public var transcriptSHA256: Data { Data(SHA256.hash(data: canonicalBytes)) }
    public init(encoded: Data) throws {
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: Self.encodedCount)
        try cursor.expect(Self.prefix)
        var hellos: [ClusterNativeKeyHello] = []
        for _ in 0..<2 { hellos.append(try .init(encoded: cursor.data(ClusterNativeKeyHello.encodedCount))) }
        try cursor.finish(); try self.init(hellos: hellos)
    }
}

struct NativeAuthorizationCursor {
    private let bytes: [UInt8]
    private var index = 0
    init(_ data: Data, exactCount: Int) throws {
        guard data.count == exactCount, exactCount <= 32 * 1024 else { throw ClusterNativeKeyError.invalidBinding }
        bytes = Array(data)
    }
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - index else { throw ClusterNativeKeyError.invalidBinding }
        defer { index += count }; return Data(bytes[index..<index + count])
    }
    mutating func expect(_ value: Data) throws {
        guard try data(value.count) == value else { throw ClusterNativeKeyError.invalidBinding }
    }
    mutating func byte() throws -> UInt8 { try data(1).first! }
    mutating func integer<T: FixedWidthInteger & UnsignedInteger>() throws -> T {
        try data(MemoryLayout<T>.size).reduce(T(0)) { ($0 << 8) | T($1) }
    }
    mutating func uuid() throws -> UUID {
        let b = Array(try data(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    func finish() throws { guard index == bytes.count else { throw ClusterNativeKeyError.invalidBinding } }
}
