import Foundation
import DarkbloomClusterProtocol

/// A private executable candidate is admissible on the installed local API,
/// never a source of coordinator/public registration or inherited text grants.
enum ClusterMiMoPrivateImagePolicy {
    static func requireCoordinatorEligible(_ capability: ClusterRuntimeCapability) throws {
        guard !capability.hasPrivateImages else {
            throw ClusterConfigurationError.invalid("Image candidate is private and unqualified; start the installed local-only cluster API")
        }
    }
    static func launchArguments(_ capability:ClusterRuntimeCapability,keyed:Bool,startupGuard:Bool) throws -> [String] {
        guard capability.hasPrivateImages else { return [] }
        guard keyed,startupGuard else {
            throw ClusterConfigurationError.invalid("Private image candidate requires keyed data plane and startup guard")
        }
        return [ClusterMiMoImageCandidate.runtimeProfileArgument,capability.profile.id,"--qualification-switches","yes"]
    }
    /// The setups whose native workers serve only on the keyed data plane:
    /// the private image candidate, and GLM, whose resident runtime refuses
    /// to load without an authenticated peer.
    static func requiresKeyedDataPlane(_ capability: ClusterRuntimeCapability) -> Bool {
        capability.hasPrivateImages || capability.adapterID == ClusterRuntimeAdapter.glm5NextLayerStage.rawValue
    }

    /// Preserve plaintext paired-link text behavior for every other setup.
    /// These alone require the already-supported native keyed path on both owner routes.
    static func keysDataPlane(_ capability: ClusterRuntimeCapability, supported: Bool,
                              sameBuild: Bool, hasLink: Bool, selectionOverride: Bool? = nil) throws -> Bool {
        let required = requiresKeyedDataPlane(capability)
        let selected = selectionOverride ?? (supported && sameBuild && (!hasLink || required))
        guard !required || (selected && supported && sameBuild) else {
            throw ClusterConfigurationError.invalid(capability.hasPrivateImages
                ? "Private image candidate requires the same keyed native worker on both ranks"
                : "This model requires the same keyed native worker on both ranks")
        }
        return selected
    }

    /// Only a setup that requires the keyed data plane (`requiresKeyedDataPlane`)
    /// accepts a launcher-issued credential on the authenticated encrypted
    /// paired-link route. Validate before the
    /// follower starts its local owner; the native worker verifies certificates.
    static func followerDataPlaneTrust(_ capability: ClusterRuntimeCapability, line: Data?,
                                       epoch: UUID, rank: Int) throws -> Data? {
        guard requiresKeyedDataPlane(capability) else {
            guard line == nil else { throw ClusterConfigurationError.invalid("Text paired-link setup does not accept a launcher-issued data-plane credential") }
            return nil
        }
        guard let line, line.count <= 4096,
              let value = try? ClusterWorkerCodec.decodeDataPlaneTrust(line),
              value.membershipEpoch == epoch, value.rank == rank else {
            throw ClusterConfigurationError.invalid("Keyed follower requires its own bounded epoch/rank data-plane credential")
        }
        return line
    }

    static func profileArguments(_ capability: ClusterRuntimeCapability) -> [String] {
        !capability.hasPrivateImages ? [] : [ClusterMiMoImageCandidate.runtimeProfileArgument,capability.profile.id]
    }
}
