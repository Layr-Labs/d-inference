import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
@testable import InstalledContract

extension InstalledSessionCheck {
    /// Fabricated metadata covers every registered text row and both private
    /// image policies. No runtime, model or image is loaded by these checks.
    static func installedDataPlanePolicy(_ base: ClusterRuntimeCapability) throws {
        let epoch = UUID(), lines = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch: epoch)
        var rows = 0
        for adapter in ClusterRuntimeAdapter.allCases {
            for row in adapter.registeredProfiles {
                let mimoImage = adapter == .mimoV26ImageCandidate
                let glmImage = adapter == .glm5NextLayerStage && row.profileID == ClusterGLMImageCandidate.profileID
                let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: base.runtimeBinarySHA256,
                    adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: row.runtimeModelID,
                    artifactSHA256: mimoImage ? ClusterMiMoImageCandidate.artifactSHA256
                        : glmImage ? ClusterGLMImageCandidate.artifactSHA256 : base.artifactSHA256,
                    configurationSHA256: mimoImage ? ClusterMiMoImageCandidate.configurationSHA256
                        : glmImage ? ClusterGLMImageCandidate.configurationSHA256 : base.configurationSHA256,
                    manifestSHA256: mimoImage ? ClusterMiMoImageCandidate.manifestSHA256
                        : glmImage ? ClusterGLMImageCandidate.manifestSHA256 : base.manifestSHA256,
                    profile: .init(id: row.profileID, vocabularySize: base.profile.vocabularySize,
                        maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320),
                    profileFingerprint: base.profileFingerprint, partitions: base.partitions,
                    arithmeticPolicyID: adapter.arithmeticPolicyID, arithmeticPolicySHA256: base.arithmeticPolicySHA256,
                    media: mimoImage ? .init() : nil, glmImages: glmImage ? .init() : nil)
                rows += 1
                try require(try ClusterMiMoPrivateImagePolicy.keysDataPlane(capability, supported: true,
                    sameBuild: true, hasLink: true), "paired-link row selected plaintext: \(row.runtimeModelID)")
                for (supported, sameBuild) in [(false, false), (false, true), (true, false)] {
                    try rejected {
                        _ = try ClusterMiMoPrivateImagePolicy.keysDataPlane(capability, supported: supported,
                            sameBuild: sameBuild, hasLink: true)
                    }
                }
                try rejected {
                    _ = try ClusterMiMoPrivateImagePolicy.keysDataPlane(capability, supported: true,
                        sameBuild: true, hasLink: true, selectionOverride: false)
                }
                // Existing GLM/private-image behavior also requires keys without
                // a link. The explicit text-only CPU/developer route stays usable.
                if capability.hasPrivateImages || adapter == .glm5NextLayerStage {
                    try rejected {
                        _ = try ClusterMiMoPrivateImagePolicy.keysDataPlane(capability, supported: true,
                            sameBuild: true, hasLink: false, selectionOverride: false)
                    }
                } else {
                    try require(try !ClusterMiMoPrivateImagePolicy.keysDataPlane(capability, supported: true,
                        sameBuild: true, hasLink: false, selectionOverride: false), "explicit CPU route changed")
                }
                for rank in 0..<2 {
                    try require(try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(capability,
                        line: lines[rank], epoch: epoch, rank: rank) == lines[rank], "own credential was not retained")
                    for bad: Data? in [nil, lines[1 - rank], Data(repeating: 0, count: 4097), Data("invalid\n".utf8)] {
                        try rejected {
                            _ = try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(capability,
                                line: bad, epoch: epoch, rank: rank)
                        }
                    }
                    try rejected {
                        _ = try ClusterMiMoPrivateImagePolicy.followerDataPlaneTrust(capability,
                            line: lines[rank], epoch: UUID(), rank: rank)
                    }
                }
            }
        }
        try require(rows == 15, "registered policy rows changed; review the fixture coverage")
        print("Installed keyed policy: 15 registered profiles; downgrade, missing/foreign/oversized credentials refused (CPU)")
    }

    /// Real CPU owners and child processes report controlled readiness. These
    /// are lifecycle/selection tests, not proof of native encryption or a load.
    static func installedDataPlaneReadiness(_ fixture: InstalledFixture,
                                            _ prepared: DistributedInstalledPreparation) async throws {
        let verified = ClusterWorkerDataPlane(protection: ClusterWorkerDataPlane.encrypted, peerVerified: true,
            transcriptSHA256: String(repeating: "a", count: 64), edgeID: String(repeating: "b", count: 32))
        let unverified = ClusterWorkerDataPlane(protection: ClusterWorkerDataPlane.encrypted, peerVerified: false,
            transcriptSHA256: verified.transcriptSHA256, edgeID: verified.edgeID)
        let other = ClusterWorkerDataPlane(protection: ClusterWorkerDataPlane.encrypted, peerVerified: true,
            transcriptSHA256: String(repeating: "c", count: 64), edgeID: verified.edgeID)
        let reports: [[ClusterWorkerDataPlane?]] = [[nil, nil], [unverified, unverified], [verified, other], [verified, verified]]
        for (index, pair) in reports.enumerated() {
            let (value, endpoints) = try session(fixture, prepared, keyed: true, dataPlanes: pair)
            var started = false
            do { try await value.start(); started = true } catch {}
            try require(started == (index == 3), "keyed readiness admitted plaintext, unverified or mismatched reports (case \(index))")
            if started {
                try require(value.status == .ready && value.diagnosticObservation.encryptedDataPlane == true
                    && value.diagnosticObservation.peerVerified == true, "keyed readiness was not published")
            } else {
                try require(value.readiness() == nil && value.status != .ready, "failed keyed startup remained routable")
                try rejected { _ = try request(value, 1) }
            }
            try require(await value.stop(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) == .released,
                "keyed startup did not release its owners")
            try require(endpoints.snapshot.count == 2 && endpoints.snapshot.allSatisfy {
                $0.nativeCleanupObserved && $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)
            }, "keyed startup discarded cleanup/release obligations")
        }
        print("Installed keyed readiness: matching verified pair admitted; plaintext, unverified and mismatched pairs refused and cleaned up (CPU)")
    }
}
