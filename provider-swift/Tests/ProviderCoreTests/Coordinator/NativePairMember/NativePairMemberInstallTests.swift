import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// What a member may register and install: the claim comes from the installed
/// control's own policy bytes, and the client accepts only that control.
@Suite("Native member installation and claim")
struct NativePairMemberInstallTests {
    private static let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4,
        chipTier: .pro, memoryGb: 24, memoryAvailableGb: 20,
        cpuCores: .init(total: 12, performance: 8, efficiency: 4), gpuCores: 16, memoryBandwidthGbs: 200)

    @Test func installationClaimsTheDigestOfItsOwnPolicyBytes() throws {
        let fixture = try MemberContractFixture()
        for rank in 0..<2 {
            let installation = fixture.installations[rank]
            let membership = try installation.membership
            #expect(membership.clusterID == "native-member-contract" && membership.rank == rank)
            #expect(membership.policySHA256 == memberHex(Data(SHA256.hash(data: installation.policy.bytes))))
            #expect(installation.policy.bytes == fixture.policy)
        }
    }

    @Test func clientInstallsOnlyTheControlWhoseClaimItRegisters() async throws {
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        let claim = try fixture.installations[0].membership
        func client(_ role: ProviderExecutionRole, _ membership: ClusterMembership?) -> CoordinatorClient {
            .init(config: .init(url: "wss://coordinator.invalid/ws", hardware: Self.hardware,
                    models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
                    backendName: "mlx-swift", executionRole: role, clusterMembership: membership),
                  stats: .init(), state: .init(), liveAPNsToken: { nil })
        }
        // No claim, the other rank's claim, another policy, and solo all refuse.
        await #expect(throws: NativePairMemberError.self) { try await client(.clusterMember, nil).installNativePairMember(control) }
        await #expect(throws: NativePairMemberError.self) {
            try await client(.clusterMember, try fixture.installations[1].membership).installNativePairMember(control)
        }
        await #expect(throws: NativePairMemberError.self) {
            try await client(.clusterMember, try ClusterMembership(clusterID: claim.clusterID, rank: 0,
                policySHA256: String(repeating: "ab", count: 32))).installNativePairMember(control)
        }
        await #expect(throws: NativePairMemberError.self) { try await client(.solo, claim).installNativePairMember(control) }
        let member = client(.clusterMember, claim)
        try await member.installNativePairMember(control)
        // Installed once; installing creates no attachment by itself.
        await #expect(throws: NativePairMemberError.self) { try await member.installNativePairMember(control) }
        #expect(await member.nativePairConnection == nil && control.status == "idle")
    }

    /// A member registers its model by the pair-serving grant, with
    /// hardware-only capabilities. GLM-5.3-Flash's single-Mac requirements
    /// (`mlx_nax`, `glm5_next_v1`) are not among them, and the member still
    /// installs its control.
    @Test func memberInstallsAModelWhoseSingleMacRequirementsItsCapabilitiesLack() async throws {
        let model = GLM5NextCoordinatorServing.catalogModelID
        let fixture = try MemberContractFixture(model: model, chip: "Apple M5 Ultra")
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        let capabilities = DistributedServingEligibility.memberCapabilities(chipFamily: .m5)
        #expect(!ModelRuntimeRequirements.isEligible(modelID: model, available: capabilities))
        let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M5 Ultra", chipFamily: .m5,
            chipTier: .ultra, memoryGb: 256, memoryAvailableGb: 240,
            cpuCores: .init(total: 32, performance: 24, efficiency: 8), gpuCores: 80, memoryBandwidthGbs: 1200)
        let member = CoordinatorClient(
            config: .init(url: "wss://coordinator.invalid/ws", hardware: hardware,
                models: [.init(id: model, modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)],
                backendName: "mlx-swift", runtimeCapabilities: capabilities, executionRole: .clusterMember,
                clusterMembership: try fixture.installations[0].membership),
            stats: .init(), state: .init(), liveAPNsToken: { nil })
        try await member.installNativePairMember(control)
        #expect(await member.nativePairConnection == nil && control.status == "idle")
    }
}
