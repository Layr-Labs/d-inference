import CryptoKit
import Foundation

// The roster registration (`cluster_membership` version 3, N18), member side.
// Mirrors darkbloom-platform coordinator/protocol/cluster_roster.go and
// cluster_membership.go; the shared vector is
// coordinator/tests/protocol/testdata/cluster_registration_vector.json.
//
// It carries no rank. It names the cluster's roster of member pins,
// countersigned by every member, this member's pin, its static device profile,
// its links to the other members, the models it holds with their artifact
// hashes and, per approved cluster policy, the plan the members derived. The
// coordinator forms a cluster from the members of one agreed plan; the plan's
// order is the rank order and its first member leads. Every value here is a
// claim the coordinator checks; none grants anything by itself.

public enum ClusterRosterError: Error, Sendable, Equatable {
    case invalidRoster
    case invalidMembership
    case invalidPlan
    case invalidProfile
}

/// The pin of a member's Secure Enclave key: lowercase hex SHA-256 of a
/// dedicated domain followed by the key's 65-byte uncompressed point.
public enum ClusterMemberPin {
    static let domain = Data("darkbloom/cluster-member-pin/v1\u{0}".utf8)

    public static func of(uncompressedKey: Data) -> String {
        hex(Data(SHA256.hash(data: domain + uncompressedKey)))
    }

    /// The pin of a base64 key given as the 65-byte uncompressed point or its
    /// 64-byte X||Y coordinates (the attestation signer's form); nil for
    /// anything that is not a point on P-256 in one of those forms.
    public static func of(sePublicKey base64: String) -> String? {
        uncompressedPoint(base64).map(of(uncompressedKey:))
    }

    static func uncompressedPoint(_ base64: String) -> Data? {
        guard var raw = Data(base64Encoded: base64) else { return nil }
        if raw.count == 64 { raw = Data([4]) + raw }
        guard raw.count == 65, (try? P256.Signing.PublicKey(x963Representation: raw)) != nil else { return nil }
        return raw
    }

    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// A cluster's member set, signed by every member. Every member registers the
/// same roster; the coordinator requires byte-equal roster hashes and never
/// adds or removes a member itself.
public struct ClusterRoster: Codable, Sendable, Equatable {
    public static let minimumMembers = 2
    public static let maximumMembers = 4
    static let domain = Data("darkbloom/cluster-roster/v1\u{0}".utf8)

    /// Increases each time the members change the roster.
    public let generation: UInt64
    /// In ascending pin order.
    public let members: [Member]

    public struct Member: Codable, Sendable, Equatable {
        /// `ClusterMemberPin` of `sePublicKey`.
        public let pin: String
        /// Canonical standard base64 of the 65-byte uncompressed P-256 point.
        public let sePublicKey: String
        /// Canonical standard base64 of the DER ECDSA P-256 signature over
        /// SHA-256 of the roster's canonical bytes, made with `sePublicKey`.
        public let signature: String

        enum CodingKeys: String, CodingKey {
            case pin
            case sePublicKey = "se_public_key"
            case signature
        }

        public init(pin: String, sePublicKey: String, signature: String) {
            self.pin = pin; self.sePublicKey = sePublicKey; self.signature = signature
        }
    }

    public init(generation: UInt64, members: [Member]) {
        self.generation = generation; self.members = members
    }

    /// The signed bytes for `clusterID`: the domain, the length-prefixed
    /// label, the generation, the member count and, per member in ascending
    /// pin order, the 32-byte pin and the length-prefixed key. Signatures are
    /// not part of their own input.
    public func canonical(clusterID: String) throws -> Data {
        try Self.canonical(clusterID: clusterID, generation: generation,
            keys: members.map { ($0.pin, $0.sePublicKey) })
    }

    /// The canonical bytes of a roster before anyone signed it, from each
    /// member's pin and key in ascending pin order.
    public static func canonical(clusterID: String, generation: UInt64, keys: [(pin: String, sePublicKey: String)]) throws -> Data {
        guard ClusterConfigurationSyntax.label(clusterID), generation > 0,
              (minimumMembers...maximumMembers).contains(keys.count) else { throw ClusterRosterError.invalidRoster }
        var bytes = domain
        append(UInt32(clusterID.utf8.count), to: &bytes); bytes.append(Data(clusterID.utf8))
        append(generation, to: &bytes); append(UInt32(keys.count), to: &bytes)
        var previous: String?
        for (pin, base64) in keys {
            guard ClusterConfigurationSyntax.hash(pin), previous.map({ pin > $0 }) ?? true,
                  let key = Data(base64Encoded: base64), key.base64EncodedString() == base64, key.count == 65,
                  ClusterMemberPin.of(uncompressedKey: key) == pin else { throw ClusterRosterError.invalidRoster }
            previous = pin
            let digits = Array(pin.utf8)
            bytes.append(contentsOf: stride(from: 0, to: 64, by: 2).map { Self.nibble(digits[$0]) << 4 | Self.nibble(digits[$0 + 1]) })
            append(UInt32(key.count), to: &bytes); bytes.append(key)
        }
        return bytes
    }

    /// The roster hash every member must register identically.
    public func sha256(clusterID: String) throws -> Data {
        Data(SHA256.hash(data: try canonical(clusterID: clusterID)))
    }

    /// The shape, and that every member signed it with the key listed for it.
    public func verify(clusterID: String) throws {
        let bytes = try canonical(clusterID: clusterID)
        for member in members {
            guard let key = Data(base64Encoded: member.sePublicKey),
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
                  let raw = Data(base64Encoded: member.signature), (8...72).contains(raw.count),
                  raw.base64EncodedString() == member.signature,
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: raw),
                  publicKey.isValidSignature(signature, for: bytes) else { throw ClusterRosterError.invalidRoster }
        }
    }

    /// This member's signature over a roster's canonical bytes, made with its
    /// Secure Enclave key (which signs SHA-256 of its input).
    public static func signature(over canonical: Data, signer: any AttestationSigner) throws -> String {
        try signer.sign(canonical).base64EncodedString()
    }

    public func hasMember(_ pin: String) -> Bool { memberKey(pin) != nil }

    public func memberKey(_ pin: String) -> String? { members.first { $0.pin == pin }?.sePublicKey }

    private static func append<T: FixedWidthInteger & UnsignedInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    /// One lowercase hex digit (already checked by `ClusterConfigurationSyntax.hash`).
    private static func nibble(_ digit: UInt8) -> UInt8 { digit <= 57 ? digit - 48 : digit - 87 }
}

/// The static description of a member's Mac as the roster registration
/// carries it (`device_profile`, device profile v2; the coordinator's
/// `ClusterDeviceProfile`, not the planner's input of that name). Static by
/// design: the members' planners derive the same plan from the same profiles,
/// and live memory is only a go/no-go when a member prepares.
public struct ClusterRegisteredDeviceProfile: Codable, Sendable, Equatable {
    /// The chip as the member's hardware report names it.
    public let chipName: String
    /// The arithmetic the GPU produces: members of one class give exactly
    /// equal results for one artifact and runtime.
    public let numericsClass: String
    public let gpuCores: UInt32
    public let memoryBytes: UInt64
    /// The wired limit less the role reserve; at most `memoryBytes`.
    public let usableWiredBytes: UInt64
    /// The macOS build string, such as 25C56.
    public let osBuild: String

    enum CodingKeys: String, CodingKey {
        case chipName = "chip_name"
        case numericsClass = "numerics_class"
        case gpuCores = "gpu_cores"
        case memoryBytes = "memory_bytes"
        case usableWiredBytes = "usable_wired_bytes"
        case osBuild = "os_build"
    }

    public init(chipName: String, numericsClass: String, gpuCores: UInt32, memoryBytes: UInt64,
                usableWiredBytes: UInt64, osBuild: String) throws {
        self.chipName = chipName; self.numericsClass = numericsClass; self.gpuCores = gpuCores
        self.memoryBytes = memoryBytes; self.usableWiredBytes = usableWiredBytes; self.osBuild = osBuild
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chipName: c.decode(String.self, forKey: .chipName),
            numericsClass: c.decode(String.self, forKey: .numericsClass), gpuCores: c.decode(UInt32.self, forKey: .gpuCores),
            memoryBytes: c.decode(UInt64.self, forKey: .memoryBytes),
            usableWiredBytes: c.decode(UInt64.self, forKey: .usableWiredBytes), osBuild: c.decode(String.self, forKey: .osBuild))
    }

    func validate() throws {
        guard ClusterRosterSyntax.printable(chipName, limit: 128), ClusterRosterSyntax.printable(numericsClass, limit: 128),
              gpuCores > 0, (1...(UInt64(1) << 44)).contains(memoryBytes), (1...memoryBytes).contains(usableWiredBytes),
              ClusterRosterSyntax.osBuild(osBuild) else { throw ClusterRosterError.invalidProfile }
    }
}

/// One confirmed link from the registering member to another roster member,
/// named only by the two member pins.
public struct ClusterEdge: Codable, Sendable, Equatable {
    public static let transports = ["rdma", "tcp_thunderbolt", "tcp_lan"]
    public let peerPin: String
    /// `rdma`, `tcp_thunderbolt` or `tcp_lan`; Wi-Fi is never a cluster link.
    public let transport: String
    public let measuredMbps: UInt32
    public let measuredRTTMicros: UInt32

    enum CodingKeys: String, CodingKey {
        case peerPin = "peer_pin"
        case transport
        case measuredMbps = "measured_mbps"
        case measuredRTTMicros = "measured_rtt_us"
    }

    public init(peerPin: String, transport: String, measuredMbps: UInt32, measuredRTTMicros: UInt32) {
        self.peerPin = peerPin; self.transport = transport
        self.measuredMbps = measuredMbps; self.measuredRTTMicros = measuredRTTMicros
    }
}

/// One model a member holds and the artifact hash it verified for it.
public struct ClusterModelArtifact: Codable, Sendable, Equatable {
    public let model: String
    public let artifactSHA256: String

    enum CodingKeys: String, CodingKey {
        case model
        case artifactSHA256 = "artifact_sha256"
    }

    public init(model: String, artifactSHA256: String) { self.model = model; self.artifactSHA256 = artifactSHA256 }
}

/// The placement the members derived for one approved cluster policy. Every
/// member the plan names must register it byte for byte.
public struct ClusterPlan: Codable, Sendable, Equatable {
    public let policySHA256: String
    public let model: String
    /// The hash of the full plan the members derived.
    public let planSHA256: String
    /// Member pins in rank order; the first leads. May name a subset of the roster.
    public let members: [String]
    /// Layer boundaries between consecutive members: rank i holds
    /// [cuts[i-1], cuts[i]). One fewer than `members`, ascending, positive.
    public let cuts: [UInt32]
    /// The generation mode the plan runs (`ClusterGenerationMode` raw value);
    /// omitted means the pipeline. Part of the placement: plans that differ in
    /// it are different plans (coordinator `ClusterPlan.Equal`).
    public let mode: String?
    /// The planner's speed estimate for one request alone on the cluster;
    /// omitted when it has none. Also part of the placement.
    public let prediction: Prediction?

    /// `protocol.ClusterPlanPrediction`.
    public struct Prediction: Codable, Sendable, Equatable {
        public let prefillTokensPerSecond: Double
        public let decodeTokensPerSecond: Double
        public let firstTokenOverheadMilliseconds: UInt32
        enum CodingKeys: String, CodingKey {
            case prefillTokensPerSecond = "prefill_tps"
            case decodeTokensPerSecond = "decode_tps"
            case firstTokenOverheadMilliseconds = "first_token_overhead_ms"
        }
        public init(prefillTokensPerSecond: Double, decodeTokensPerSecond: Double, firstTokenOverheadMilliseconds: UInt32) {
            self.prefillTokensPerSecond = prefillTokensPerSecond; self.decodeTokensPerSecond = decodeTokensPerSecond
            self.firstTokenOverheadMilliseconds = firstTokenOverheadMilliseconds
        }
        /// Rates no Mac exceeds, an overhead of at most a minute.
        func validate() throws {
            guard prefillTokensPerSecond > 0, prefillTokensPerSecond <= 1_000_000,
                  decodeTokensPerSecond > 0, decodeTokensPerSecond <= 10_000,
                  firstTokenOverheadMilliseconds <= 60_000 else { throw ClusterRosterError.invalidPlan }
        }
    }

    /// The generation modes a plan may name (`protocol.ClusterPlanModes`).
    /// `pipeline_mtp_v1` (a pipeline's speculative rounds, planned by default
    /// where its records pass and measured it faster) needs the coordinator's
    /// list to name it too before a role-aware coordinator accepts such a plan.
    public static let modes = ["pipeline_v1", "pipeline_compact_decode_v1", "phase_split_v1", "phase_split_mtp_v1", "pipeline_mtp_v1"]

    enum CodingKeys: String, CodingKey {
        case policySHA256 = "policy_sha256"
        case model
        case planSHA256 = "plan_sha256"
        case members, cuts, mode, prediction
    }

    public init(policySHA256: String, model: String, planSHA256: String, members: [String], cuts: [UInt32],
                mode: String? = nil, prediction: Prediction? = nil) {
        self.policySHA256 = policySHA256; self.model = model; self.planSHA256 = planSHA256
        self.members = members; self.cuts = cuts; self.mode = mode; self.prediction = prediction
    }

    /// The plan's generation mode, the pipeline when omitted.
    public var effectiveMode: String { mode ?? "pipeline_v1" }

    /// Byte for byte the same placement, as the coordinator compares plans.
    public func samePlacement(as other: ClusterPlan) -> Bool {
        policySHA256 == other.policySHA256 && model == other.model && planSHA256 == other.planSHA256
            && members == other.members && cuts == other.cuts && effectiveMode == other.effectiveMode
            && prediction == other.prediction
    }

    func validate(roster: ClusterRoster) throws {
        guard ClusterConfigurationSyntax.hash(policySHA256), ClusterConfigurationSyntax.hash(planSHA256),
              ClusterRosterSyntax.modelName(model),
              (ClusterRoster.minimumMembers...ClusterRoster.maximumMembers).contains(members.count),
              cuts.count == members.count - 1, Set(members).count == members.count,
              members.allSatisfy(roster.hasMember),
              cuts.allSatisfy({ $0 > 0 }), zip(cuts, cuts.dropFirst()).allSatisfy({ $0 < $1 }),
              mode.map({ Self.modes.contains($0) }) ?? true else {
            throw ClusterRosterError.invalidPlan
        }
        try prediction?.validate()
    }
}

enum ClusterRosterSyntax {
    static let inventoryLimit = 64
    static let planLimit = 16

    static func printable(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy { (0x20...0x7e).contains($0) }
    }

    static func osBuild(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func modelName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 }

    /// A 16-byte epoch in lowercase hex, not all zero, as the frames carry it.
    static func epoch(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && value.utf8.contains { $0 != 48 }
    }
}
