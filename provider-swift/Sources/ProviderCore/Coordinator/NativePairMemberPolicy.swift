import Foundation

/// Strict reader for the coordinator-owned B policy bytes. Parsing establishes
/// equality only; approval is accepted exclusively on the live WSS connection.
struct NativePairMemberPolicy: Sendable {
    let bytes: Data
    let model: String
    let generation: UInt64
    /// The model's artifact digest, which every approval names.
    let artifact: Data
    /// A pair approval's fixed plan, or a build-pinned cluster approval's
    /// placement policy (no member check reads it); nil for a model approval.
    let pinnedPlan: Data?
    /// The runtime a pair or build-pinned cluster approval pins; nil for a
    /// model approval, whose members take it from their own saved setups.
    let runtime: Runtime?
    /// The runtime digests a member starts with and hashes its files against.
    struct Runtime: Sendable, Equatable {
        let nativeRuntime, metallib, resourceLibrary, capability, resourcePolicy, profile: Data

        /// From a plan's runtime block (the member's own setup) and the
        /// digests the member took of its installed metallib and resource
        /// library; nil when a value is not 64 lowercase hex characters.
        init?(_ block: ClusterPlan.Runtime, metallibSHA256: String, resourceLibrarySHA256: String) {
            let values = [block.nativeRuntimeSHA256, metallibSHA256, resourceLibrarySHA256, block.capabilitySHA256,
                          block.resourcePolicySHA256, block.profileSHA256].compactMap(NativePairMemberPolicy.digest(hex:))
            guard values.count == 6 else { return nil }
            self.init(values)
        }

        /// The six digests in canonical order (worker, metallib, resource library, capability, resource policy, profile).
        init(_ values: [Data]) {
            nativeRuntime = values[0]; metallib = values[1]; resourceLibrary = values[2]
            capability = values[3]; resourcePolicy = values[4]; profile = values[5]
        }

        /// The four digests a start carries, as a plan's runtime block names them.
        var block: ClusterPlan.Runtime {
            .init(nativeRuntimeSHA256: NativePairMemberPolicy.hex(nativeRuntime),
                  capabilitySHA256: NativePairMemberPolicy.hex(capability),
                  resourcePolicySHA256: NativePairMemberPolicy.hex(resourcePolicy),
                  profileSHA256: NativePairMemberPolicy.hex(profile))
        }
    }
    let schedule: UInt8
    let maximumFrame, maximumPlaintext: UInt32
    let maximumRecords, maximumCumulative, notAfter: UInt64
    /// A pair approval's qualified chips; empty for a cluster approval.
    let chips: [String]
    /// A cluster approval's terms (`darkbloom/coordinator-cluster-runtime-approval/v1`,
    /// or a model approval's `darkbloom/coordinator-cluster-model-approval/v1`);
    /// nil for a pair approval.
    let cluster: Cluster?
    struct Cluster: Sendable, Equatable {
        let minimumMembers, maximumMembers: Int
        let minimumMemberUsableBytes: UInt64
        let leaseTermsNanoseconds: [UInt64]
        /// The numerics classes the approval lists; empty admits any class
        /// (chip-agnostic; owner, 2026-10-14).
        let numericsClasses: [String]

        /// Whether a member of this numerics class is covered: any class when
        /// the approval lists none, otherwise a listed one.
        func admits(numericsClass: String) -> Bool {
            !numericsClass.isEmpty && (numericsClasses.isEmpty || numericsClasses.contains(numericsClass))
        }
    }
    static let pairDomain = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8)
    static let clusterDomain = Data("darkbloom/coordinator-cluster-runtime-approval/v1\0".utf8)
    /// A cluster approval that pins no build (contract M2): the cluster layout
    /// without the placement digest and the six runtime digests.
    static let modelDomain = Data("darkbloom/coordinator-cluster-model-approval/v1\0".utf8)
    init(_ bytes: Data) throws {
        guard bytes.count <= 8192 else { throw NativePairMemberError.binding }
        var r = Reader(bytes)
        let isModel = bytes.starts(with: Self.modelDomain)
        let isCluster = isModel || bytes.starts(with: Self.clusterDomain)
        try r.literal(isModel ? Self.modelDomain : isCluster ? Self.clusterDomain : Self.pairDomain)
        _ = try r.string(maximum: 128) // Policy ID is included in the exact digest.
        model = try r.string(maximum: 512); generation = try r.integer(UInt64.self)
        let hashes = try (0..<(isModel ? 1 : 8)).map { _ in try r.read(32) }
        if isModel {
            artifact = hashes[0]; pinnedPlan = nil; runtime = nil
        } else {
            pinnedPlan = hashes[0]; artifact = hashes[1]; runtime = Runtime(Array(hashes[2...]))
        }
        try r.literal(Data([1, 1])); schedule = try r.integer(UInt8.self)
        maximumFrame = try r.integer(UInt32.self); maximumPlaintext = try r.integer(UInt32.self)
        maximumRecords = try r.integer(UInt64.self); maximumCumulative = try r.integer(UInt64.self)
        notAfter = try r.integer(UInt64.self)
        var terms: Cluster?
        if isCluster {
            let minimum = Int(try r.integer(UInt8.self)), maximum = Int(try r.integer(UInt8.self))
            let usable = try r.integer(UInt64.self)
            let lease = try (0..<3).map { _ in try r.integer(UInt64.self) }
            guard (2...4).contains(minimum), (2...4).contains(maximum), minimum <= maximum, usable > 0,
                  lease.allSatisfy({ $0 > 0 }) else { throw NativePairMemberError.binding }
            terms = .init(minimumMembers: minimum, maximumMembers: maximum, minimumMemberUsableBytes: usable,
                leaseTermsNanoseconds: lease, numericsClasses: [])
        }
        // A pair approval names 1-16 chips; a cluster approval up to 16
        // numerics classes, none meaning any class.
        let count = try r.integer(UInt32.self)
        guard (isCluster ? 0...16 : 1...16).contains(count) else { throw NativePairMemberError.binding }
        let names = try (0..<count).map { _ in try r.string(maximum: 128) }
        guard names.allSatisfy({ $0.utf8.allSatisfy { (0x20...0x7e).contains($0) } }) || !isCluster else {
            throw NativePairMemberError.binding
        }
        if let value = terms {
            cluster = .init(minimumMembers: value.minimumMembers, maximumMembers: value.maximumMembers,
                minimumMemberUsableBytes: value.minimumMemberUsableBytes,
                leaseTermsNanoseconds: value.leaseTermsNanoseconds, numericsClasses: names)
            chips = []
        } else { cluster = nil; chips = names }
        guard r.remaining == 0, generation > 0, (1...2).contains(schedule),
              hashes.allSatisfy({ !$0.allSatisfy({ $0 == 0 }) }), names == names.sorted(), Set(names).count == names.count,
              maximumPlaintext > 0, maximumPlaintext <= 16 * 1024 * 1024,
              maximumFrame >= maximumPlaintext + 40, maximumFrame <= 16 * 1024 * 1024 + 40,
              (1...1_048_576).contains(maximumRecords), (1...4_294_967_296).contains(maximumCumulative),
              notAfter > 0, notAfter <= UInt64(Int64.max) else { throw NativePairMemberError.binding }
        self.bytes = bytes
    }
    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func read(_ n: Int) throws -> Data {
            guard n >= 0, n <= remaining else { throw NativePairMemberError.binding }
            defer { offset += n }; return data.subdata(in: offset..<(offset + n))
        }
        mutating func literal(_ expected: Data) throws {
            guard try read(expected.count) == expected else { throw NativePairMemberError.binding }
        }
        mutating func integer<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
            try read(MemoryLayout<T>.size).reduce(0) { ($0 << 8) | T($1) }
        }
        mutating func string(maximum: Int) throws -> String {
            let n = try integer(UInt32.self)
            guard n > 0, Int(n) <= maximum, let s = String(data: try read(Int(n)), encoding: .utf8) else { throw NativePairMemberError.binding }
            return s
        }
    }

    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// The 32 bytes of a digest given as 64 lowercase hex characters; nil for anything else.
    static func digest(hex text: String) -> Data? {
        guard ClusterConfigurationSyntax.hash(text) else { return nil }
        let digits = Array(text.utf8).map { $0 < 58 ? $0 - 48 : $0 - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    }
}

enum NativePairMemberError: Error { case binding, deadline, inactive, queue, unconfigured }
