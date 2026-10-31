import CryptoKit
import Foundation

// The outer version is closed and determines every nested byte count. A finite
// common cannot be smuggled into a serving start/hello/binding or vice versa.
enum NativeAuthorizationWire: UInt8 {
    case serving = 1, finiteCalibration = 2
    init(common: ClusterNativeAuthorizationCommon) {
        switch common.permission {
        case .servingV1: self = .serving
        case .finiteCalibrationV1: self = .finiteCalibration
        }
    }
    var commonCount: Int {
        switch self {
        case .serving: return ClusterNativeAuthorizationCommon.encodedCount
        case .finiteCalibration: return ClusterNativeAuthorizationCommon.finiteEncodedCount
        }
    }
    var startCount: Int { 5 + commonCount + 1 + 3 * 16 }
    var helloCount: Int { 5 + startCount + 32 }
    var bindingCount: Int { 5 + 2 * helloCount }
    static func decode(_ data: Data, marker: UInt8) throws -> Self {
        guard data.count >= 5, Data(data.prefix(4)) == Data([0x44, 0x42, 0x4e, marker]),
              let version = Self(rawValue: data[data.startIndex + 4]) else { throw ClusterNativeKeyError.invalidBinding }
        return version
    }
    func prefix(_ marker: UInt8) -> Data { Data([0x44, 0x42, 0x4e, marker, rawValue]) }
}

extension ClusterNativeAuthorizationCommon {
    static let domain = Data("darkbloom/native-authorization/common/v1\0".utf8)
    static let encodedCount = domain.count + 16 + 8 + 8 + 8 * 32 + 3 + 4 + 4 + 8 + 8
    static let finiteDomain = Data("darkbloom/native-authorization/glm-finite-calibration/v1\0".utf8)
    static let finiteEncodedCount = finiteDomain.count + 16 + 8 + 6 * 32 + 16 + 8 + 4 + 4 + 4 + 8 + 8
    public var canonicalBytes: Data {
        var bytes: Data
        switch permission {
        case .servingV1(let serving):
            bytes = Self.domain
            bytes.append(clusterRecordUUIDBytes(epoch))
            bytes.clusterAppendBigEndian(membershipGeneration); bytes.clusterAppendBigEndian(serving.nativePolicyGeneration)
            for digest in [membershipTranscriptSHA256, serving.approvedNativeBindingSHA256, planSHA256, artifactSHA256,
                           serving.nativeRuntimeSHA256, serving.capabilitySHA256, serving.resourcePolicySHA256, profileSHA256] {
                bytes.append(digest)
            }
            bytes.append(contentsOf: [1, 1, schedule.rawValue])
        case .finiteCalibrationV1(let finite):
            bytes = Self.finiteDomain
            bytes.append(clusterRecordUUIDBytes(epoch)); bytes.clusterAppendBigEndian(membershipGeneration)
            for digest in [membershipTranscriptSHA256, planSHA256, artifactSHA256, profileSHA256,
                           finite.rank0AuthorizationSHA256, finite.rank1AuthorizationSHA256] { bytes.append(digest) }
            bytes.append(clusterRecordUUIDBytes(finite.requestID)); bytes.clusterAppendBigEndian(UInt64(finite.expiresUnixSeconds))
            // Closed suite, JACCL P2P, serial schedule, exactly one cold-text request.
            bytes.append(contentsOf: [1, 1, 1, 1])
        }
        bytes.clusterAppendBigEndian(UInt32(maximumTransportFrameBytes)); bytes.append(limits.canonicalBytes)
        return bytes
    }
    init(cursor: inout NativeAuthorizationCursor, version: NativeAuthorizationWire = .serving) throws {
        switch version {
        case .serving:
            try cursor.expect(Self.domain)
            let epoch = try cursor.uuid(), generation: UInt64 = try cursor.integer(), policy: UInt64 = try cursor.integer()
            var digests: [Data] = []
            for _ in 0..<8 { digests.append(try cursor.data(32)) }
            try cursor.expect(Data([1, 1]))
            guard let schedule = ClusterNativePrefillSchedule(rawValue: try cursor.byte()) else { throw ClusterNativeKeyError.invalidBinding }
            let (frame, limits) = try Self.readLimits(&cursor)
            try self.init(epoch: epoch, membershipGeneration: generation, nativePolicyGeneration: policy,
                membershipTranscriptSHA256: digests[0], approvedNativeBindingSHA256: digests[1], planSHA256: digests[2],
                artifactSHA256: digests[3], nativeRuntimeSHA256: digests[4], capabilitySHA256: digests[5],
                resourcePolicySHA256: digests[6], profileSHA256: digests[7], schedule: schedule,
                maximumTransportFrameBytes: frame, limits: limits)
        case .finiteCalibration:
            try cursor.expect(Self.finiteDomain)
            let epoch = try cursor.uuid(), generation: UInt64 = try cursor.integer()
            var digests: [Data] = []
            for _ in 0..<6 { digests.append(try cursor.data(32)) }
            let request = try cursor.uuid(), expiry: UInt64 = try cursor.integer()
            guard expiry <= UInt64(Int64.max) else { throw ClusterNativeKeyError.invalidBinding }
            try cursor.expect(Data([1, 1, 1, 1]))
            let (frame, limits) = try Self.readLimits(&cursor)
            try self.init(finiteCalibrationRequestID: request, expiresUnixSeconds: Int64(expiry),
                epoch: epoch, membershipGeneration: generation, membershipTranscriptSHA256: digests[0],
                planSHA256: digests[1], artifactSHA256: digests[2], profileSHA256: digests[3],
                rank0AuthorizationSHA256: digests[4], rank1AuthorizationSHA256: digests[5],
                maximumTransportFrameBytes: frame, limits: limits)
        }
    }
    private static func readLimits(_ cursor: inout NativeAuthorizationCursor) throws -> (Int, ClusterRecordLimits) {
        let frame: UInt32 = try cursor.integer(), plaintext: UInt32 = try cursor.integer()
        let records: UInt64 = try cursor.integer(), total: UInt64 = try cursor.integer()
        return (Int(frame), try ClusterRecordLimits(maximumPlaintextBytes: Int(plaintext),
            maximumRecordsPerDirection: records, maximumCumulativePlaintextBytesPerDirection: total))
    }
}

extension ClusterNativeAuthorizationStart {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x53, 1])
    static let encodedCount = prefix.count + ClusterNativeAuthorizationCommon.encodedCount + 1 + 3 * 16
    public var canonicalBytes: Data {
        var bytes = NativeAuthorizationWire(common: common).prefix(0x53)
        bytes.append(common.canonicalBytes); bytes.append(UInt8(rank))
        for id in [ownerIncarnation, leaseID, launchID] { bytes.append(clusterRecordUUIDBytes(id)) }
        return bytes
    }
    public init(encoded: Data) throws {
        let version = try NativeAuthorizationWire.decode(encoded, marker: 0x53)
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: version.startCount)
        try cursor.expect(version.prefix(0x53))
        let common = try ClusterNativeAuthorizationCommon(cursor: &cursor, version: version), rank = try cursor.byte()
        try self.init(common: common, rank: Int(rank), ownerIncarnation: cursor.uuid(), leaseID: cursor.uuid(), launchID: cursor.uuid())
        try cursor.finish()
    }
}

extension ClusterNativeKeyHello {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x48, 1])
    static let encodedCount = prefix.count + ClusterNativeAuthorizationStart.encodedCount + 32
    public var canonicalBytes: Data {
        var bytes = NativeAuthorizationWire(common: start.common).prefix(0x48)
        bytes.append(start.canonicalBytes); bytes.append(publicKey); return bytes
    }
    public init(encoded: Data) throws {
        let version = try NativeAuthorizationWire.decode(encoded, marker: 0x48)
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: version.helloCount)
        try cursor.expect(version.prefix(0x48))
        let start = try ClusterNativeAuthorizationStart(encoded: cursor.data(version.startCount))
        guard NativeAuthorizationWire(common: start.common) == version else { throw ClusterNativeKeyError.invalidBinding }
        try self.init(start: start, publicKey: cursor.data(32)); try cursor.finish()
    }
}

extension ClusterNativeKeyBinding {
    static let prefix = Data([0x44, 0x42, 0x4e, 0x42, 1])
    /// Legacy serving-v1 byte count. Use canonicalBytes.count for a value;
    /// decoding validates the exact count for its closed outer version.
    public static let encodedCount = prefix.count + 2 * ClusterNativeKeyHello.encodedCount
    public var canonicalBytes: Data {
        var bytes = NativeAuthorizationWire(common: hellos[0].start.common).prefix(0x42)
        for hello in hellos { bytes.append(hello.canonicalBytes) }
        return bytes
    }
    public var transcriptSHA256: Data { Data(SHA256.hash(data: canonicalBytes)) }
    public init(encoded: Data) throws {
        let version = try NativeAuthorizationWire.decode(encoded, marker: 0x42)
        var cursor = try NativeAuthorizationCursor(encoded, exactCount: version.bindingCount)
        try cursor.expect(version.prefix(0x42))
        var hellos: [ClusterNativeKeyHello] = []
        for _ in 0..<2 {
            let hello = try ClusterNativeKeyHello(encoded: cursor.data(version.helloCount))
            guard NativeAuthorizationWire(common: hello.start.common) == version else { throw ClusterNativeKeyError.invalidBinding }
            hellos.append(hello)
        }
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
