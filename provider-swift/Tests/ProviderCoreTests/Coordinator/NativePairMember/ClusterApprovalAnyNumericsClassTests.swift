import Foundation
import Testing
@testable import ProviderCore

/// A cluster approval that lists no numerics class admits a member of any
/// class (owner, 2026-10-14: chips and memory do not gate what is offered).
/// Its canonical bytes carry a class count of zero, as the coordinator encodes
/// them (darkbloom-platform `canonicalClusterRuntimeApproval` with
/// `allowed_numerics_classes: []`, printed once from f760595c).
@Suite struct ClusterApprovalAnyNumericsClassTests {
    static let coordinatorCanonicalHex = "6461726b626c6f6f6d2f636f6f7264696e61746f722d636c75737465722d72756e74696d652d617070726f76616c2f763100000000157075622d636c75737465722d7177656e33352d3962000000186d6c782d636f6d6d756e6974792f5177656e332e352d394200000000000000030101010101010101010101010101010101010101010101010101010101010101020202020202020202020202020202020202020202020202020202020202020203030303030303030303030303030303030303030303030303030303030303030404040404040404040404040404040404040404040404040404040404040404050505050505050505050505050505050505050505050505050505050505050506060606060606060606060606060606060606060606060606060606060606060707070707070707070707070707070707070707070707070707070707070707080808080808080808080808080808080808080808080808080808080808080801010100100028001000000000000000100000000000010000000018f67c24e00236000202000000100000000000000009502f90000000001bf08eb00000000014f46b040000000000"

    static func approval(classes: [String]) -> ClusterRuntimeApproval {
        func h(_ b: UInt8) -> String { String(repeating: String(format: "%02x", b), count: 32) }
        return ClusterRuntimeApproval(id: "pub-cluster-qwen35-9b", model: "mlx-community/Qwen3.5-9B", generation: 3,
            placementPolicySHA256: h(1), artifactSHA256: h(2), nativeRuntimeSHA256: h(3), metallibSHA256: h(4),
            resourceLibrarySHA256: h(5), capabilitySHA256: h(6), resourcePolicySHA256: h(7), profileSHA256: h(8),
            schedule: 1, maximumTransportFrame: 1_048_616, maximumPlaintext: 1_048_576, maximumRecords: 1_048_576,
            maximumCumulativePlaintext: 4_294_967_296, allowedNumericsClasses: classes, minimumMembers: 2, maximumMembers: 2,
            minimumMemberUsableBytes: 64 << 30, notAfter: "2026-12-31T23:59:59Z")
    }

    @Test func anEmptyClassListMatchesTheCoordinatorAndAdmitsAnyClass() throws {
        let bytes = try Self.approval(classes: []).canonicalPolicy()
        #expect(bytes.map { String(format: "%02x", $0) }.joined() == Self.coordinatorCanonicalHex)
        let policy = try NativePairMemberPolicy(bytes)
        let terms = try #require(policy.cluster)
        #expect(terms.numericsClasses.isEmpty && policy.chips.isEmpty)
        for numericsClass in ["g16s-nax0-mlx-f7fb1831-macos27.2", "g15d-nax0-mlx-f7fb1831-macos26.2", "g17d-nax1-mlx-f7fb1831-macos27.2"] {
            #expect(terms.admits(numericsClass: numericsClass), "\(numericsClass)")
        }
        #expect(!terms.admits(numericsClass: ""))
    }

    @Test func aListedClassStillDecidesWhenTheOperatorListsOne() throws {
        let policy = try NativePairMemberPolicy(try Self.approval(classes: ["g15d-nax0-mlx-f7fb1831-macos26.2"]).canonicalPolicy())
        let terms = try #require(policy.cluster)
        #expect(terms.admits(numericsClass: "g15d-nax0-mlx-f7fb1831-macos26.2"))
        #expect(!terms.admits(numericsClass: "g16s-nax0-mlx-f7fb1831-macos27.2"))
    }

    /// A pair approval (the fixed-plan path) still names at least one chip.
    @Test func aPairApprovalStillNamesItsChips() throws {
        var bytes = try Self.approval(classes: []).canonicalPolicy()
        bytes.replaceSubrange(0..<NativePairMemberPolicy.clusterDomain.count, with: NativePairMemberPolicy.pairDomain)
        #expect(throws: (any Error).self) { _ = try NativePairMemberPolicy(bytes) }
    }
}
