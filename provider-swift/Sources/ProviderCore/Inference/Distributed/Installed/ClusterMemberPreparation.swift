import Foundation
import DarkbloomClusterProcess
import ProviderCoreFoundation

/// Validates this Mac's installed setup without retaining a device lease. The
/// future native owner must acquire its own canonical lease before it starts.
/// An empty journal alone is insufficient: startup briefly takes the exact
/// existing exclusive gate, so live solo/native ownership and sticky journals
/// refuse member startup. No recovery or journal clearing occurs here.
public struct ClusterMemberPreparation: Sendable {
    public let model: ModelInfo
    private let validation: DistributedInstalledValidation

    public static func prepare(reference: ClusterConfigurationReference) throws -> Self {
        let paths = try ClusterUserPaths()
        let gate = try ClusterDeviceExclusion(directoryURL: paths.deviceDirectory)
        return try withExtendedLifetime(gate) {
            let validation = try DistributedInstalledValidation.validate(reference: reference,
                paths: paths, deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
            let installed = validation.model
            guard var model = ModelScanner.parseModelInfo(snapshotDir: installed.directory,
                    modelName: installed.publicModelID) else {
                throw ClusterMemberControlError.incompatibleConfiguration
            }
            // Same on-demand integrity hasher as ordinary registration. This is
            // the ONE selected cluster model, not a discovery-wide payload scan.
            // WeightHasher is synchronous and has no cancellation/deadline API.
            // This full read is outside the metadata probe's 15-second budget;
            // the CLI owns/awaits it before any native owner or ACK timer starts.
            guard let hash = WeightHasher.computeHash(snapshotDir: installed.directory,
                    modelID: installed.publicModelID), hash == validation.manifest.aggregateSHA256 else {
                throw ClusterConfigurationError.invalid("Cluster member model integrity differs from the pinned product manifest")
            }
            model.weightHash = hash
            try validation.requireUnchanged()
            return Self(model: model, validation: validation)
        }
    }

    public func requireUnchanged() throws { try validation.requireUnchanged() }
}
