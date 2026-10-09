import Foundation

/// The doctor's check of this Mac's saved setup against its installation.
enum ClusterInstalledMetadataChecks {
    /// Runs the validation every start runs. A model that is not served on a
    /// pair is reported as that, not as a metadata fault.
    static func localInstalledMetadata(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                                       deadline: UInt64) -> [ClusterDiagnosticsReport.Check] {
        do {
            _ = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
            return [.init(name: "localInstalledMetadata", outcome: .passed,
                detail: "Local worker hash, config/manifest/tokenizer pins, trust-file metadata/pin and installed runtime description verified. Weight payloads and SSH authentication were not tested.")]
        } catch let refusal as DistributedInstalledServingRefusal {
            return [.init(name: "pairServingPolicy", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(refusal)),
                    .init(name: "localInstalledMetadata", outcome: .notRun,
                          detail: "Not examined: this setup's model is not served on a pair.")]
        } catch {
            return [.init(name: "localInstalledMetadata", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(error))]
        }
    }
}
