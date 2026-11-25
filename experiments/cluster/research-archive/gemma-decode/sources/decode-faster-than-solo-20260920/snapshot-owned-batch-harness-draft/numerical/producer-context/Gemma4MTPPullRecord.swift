import CryptoKit
import Foundation

/// Closed depth-two request protocol. No message asserts native/process release.
/// One command and its response share a sequence; both endpoints advance once.
struct Gemma4MTPPullRecord: Equatable {
    enum Kind: UInt32 {
        case seed = 1, seeded, credit, queued, pull, proposals
        case resolve, resolved, retire, retired, finish, finished, cancel, cancelled
    }
    struct Failure: Error { let reason: String }
    // 256-byte record carried in the already-qualified fixed 16 KiB CPU frame.
    static let byteCount = 16 * 1024
    static let maximumDraftTokens = 2
    static let maximumBufferedProposals = 5
    let kind: Kind
    let sequence: UInt64
    let scopeSHA256: String
    let branchOrdinal: UInt64
    let snapshotFrontier: Int
    let snapshotSHA256: String
    var frontier = 0, seed = 0, firstPosition = 0, count = 0, accepted = 0
    var windowOrdinal: UInt64 = 0
    var hiddenDType = 0
    var tokens: [Int] = []

    init(kind: Kind, sequence: UInt64, scopeSHA256: String,
         branch: AsyncMTPProposalLedger.BranchID) {
        self.kind = kind; self.sequence = sequence; self.scopeSHA256 = scopeSHA256
        branchOrdinal = branch.ordinal; snapshotFrontier = branch.snapshotFrontier
        snapshotSHA256 = branch.snapshotSHA256
    }

    private init(kind: Kind, sequence: UInt64, scopeSHA256: String,
                 branchOrdinal: UInt64, snapshotFrontier: Int, snapshotSHA256: String) {
        self.kind = kind; self.sequence = sequence; self.scopeSHA256 = scopeSHA256
        self.branchOrdinal = branchOrdinal; self.snapshotFrontier = snapshotFrontier
        self.snapshotSHA256 = snapshotSHA256
    }

    func changingKind(_ next: Kind) -> Self {
        var result = Self(kind: next, sequence: sequence, scopeSHA256: scopeSHA256,
            branchOrdinal: branchOrdinal, snapshotFrontier: snapshotFrontier, snapshotSHA256: snapshotSHA256)
        result.frontier = frontier; result.seed = seed; result.firstPosition = firstPosition
        result.count = count; result.accepted = accepted; result.windowOrdinal = windowOrdinal
        result.hiddenDType = hiddenDType; result.tokens = tokens
        return result
    }

    func encode() throws -> Data {
        guard Self.isSHA(scopeSHA256), Self.isSHA(snapshotSHA256),
              (1...8319).contains(snapshotFrontier), tokens.count <= 3,
              [frontier, seed, firstPosition, count, accepted, hiddenDType].allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) }),
              tokens.allSatisfy({ (0..<262_144).contains($0) }) else {
            throw Failure(reason: "Pull record exceeds its closed scalar bounds")
        }
        var data = Data("G4MTPP01".utf8)
        func u32(_ value: Int) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((UInt64(value) >> shift) & 255)) } }
        func u64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((value >> shift) & 255)) } }
        u32(1); u32(Int(kind.rawValue)); u64(sequence); u64(branchOrdinal)
        u32(snapshotFrontier); u32(frontier); u32(seed); u32(firstPosition); u32(count); u32(accepted)
        u64(windowOrdinal); u32(hiddenDType); u32(tokens.count)
        for index in 0..<3 { u32(index < tokens.count ? tokens[index] : 0) }
        data.append(contentsOf: Self.digestBytes(scopeSHA256)); data.append(contentsOf: Self.digestBytes(snapshotSHA256))
        data.append(Data(repeating: 0, count: Self.byteCount - data.count))
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        guard bytes.count == byteCount, Array(bytes[0..<8]) == Array("G4MTPP01".utf8),
              bytes[148...].allSatisfy({ $0 == 0 }) else { throw Failure(reason: "Pull frame length, magic or padding differs") }
        func u32(_ index: Int) -> Int { bytes[index..<index+4].reduce(0) { ($0 << 8) | Int($1) } }
        func u64(_ index: Int) -> UInt64 { bytes[index..<index+8].reduce(0) { ($0 << 8) | UInt64($1) } }
        func hex(_ index: Int) -> String { bytes[index..<index+32].map { String(format: "%02x", $0) }.joined() }
        guard u32(8) == 1, let kind = Kind(rawValue: UInt32(u32(12))), u32(68) <= 3 else {
            throw Failure(reason: "Pull frame version, opcode or token bound differs")
        }
        var result = Self(kind: kind, sequence: u64(16), scopeSHA256: hex(84),
            branchOrdinal: u64(24), snapshotFrontier: u32(32), snapshotSHA256: hex(116))
        result.frontier = u32(36); result.seed = u32(40); result.firstPosition = u32(44)
        result.count = u32(48); result.accepted = u32(52); result.windowOrdinal = u64(56)
        result.hiddenDType = u32(64); result.tokens = (0..<u32(68)).map { u32(72 + 4*$0) }
        guard try result.encode() == data else { throw Failure(reason: "Pull frame is not its canonical fixed representation") }
        return result
    }

    static func scopeFingerprint(_ scope: AsyncMTPProposalLedger.Scope, requestSHA256: String,
                                 initialFrontier: Int, maximumInputFrontier: Int) -> String {
        digest(Data((["gemma4_mtp_pull_k2_v1", scope.requestID.uuidString.lowercased(),
            scope.membershipEpoch.uuidString.lowercased(), scope.targetBuildSHA256, scope.assistantBuildSHA256,
            scope.targetArtifactSHA256, scope.assistantArtifactSHA256, scope.embeddingIdentitySHA256,
            requestSHA256, String(initialFrontier), String(maximumInputFrontier)].joined(separator: "\n") + "\n").utf8))
    }
    /// Capture identity binds exact scope/frontier/seed/type, not KV contents.
    /// Actual capture provenance comes from the target owner and completed tensors.
    static func captureFingerprint(scope: String, ordinal: UInt64, frontier: Int, seed: Int, hiddenDType: Int) -> String {
        digest(Data("gemma4_mtp_capture_identity_v1\n\(scope)\n\(ordinal)\n\(frontier)\n\(seed)\n\(hiddenDType)\n".utf8))
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digestBytes(_ text: String) -> [UInt8] {
        stride(from: 0, to: 64, by: 2).map { index in
            let start = text.index(text.startIndex, offsetBy: index)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
