import Foundation

/// The doctor's check of this Mac's saved setup against its installation.
enum ClusterInstalledMetadataChecks {
    /// Runs the validation every start runs, then the owner's serving check
    /// for the rank this Mac runs, with `localChipClass` (this Mac's own class
    /// on a real Mac). A model no stage adapter runs, or a rank-shape that
    /// diverged, is reported as that, under `pairServingPolicy`, not as a
    /// metadata fault.
    static func localInstalledMetadata(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                                       deadline: UInt64, localChipClass: ClusterChipClass?) -> [ClusterDiagnosticsReport.Check] {
        let validation: DistributedInstalledValidation
        do {
            validation = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
        } catch let refusal as ClusterPairServingRefusal {
            return refused(refusal)
        } catch {
            return [.init(name: "localInstalledMetadata", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(error))]
        }
        let metadata = ClusterDiagnosticsReport.Check(name: "localInstalledMetadata", outcome: .passed,
            detail: "Local worker hash, config/manifest/tokenizer pins, trust-file metadata/pin and installed runtime description verified. Weight payloads and SSH authentication were not tested.")
        do {
            try validation.plan.requireLocalRankGranted(chipClass: localChipClass)
        } catch {
            return [.init(name: "pairServingPolicy", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(error)), metadata]
        }
        return [metadata]
    }

    private static func refused(_ refusal: Error) -> [ClusterDiagnosticsReport.Check] {
        [.init(name: "pairServingPolicy", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(refusal)),
         .init(name: "localInstalledMetadata", outcome: .notRun,
               detail: "Not examined: this setup's model is not served on a pair.")]
    }
}
