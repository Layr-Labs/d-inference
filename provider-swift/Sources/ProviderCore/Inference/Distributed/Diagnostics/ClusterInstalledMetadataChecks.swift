import Foundation

/// The doctor's check of this Mac's saved setup against its installation.
enum ClusterInstalledMetadataChecks {
    /// Runs the validation every start runs, then the model's pair-serving
    /// grant for the rank this Mac runs, with `localNumericsClass` (this Mac's
    /// own class on a real Mac). A model or placement a pair may not serve is
    /// reported as that, under `pairServingPolicy`, not as a metadata fault.
    static func localInstalledMetadata(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                                       deadline: UInt64, localNumericsClass: ClusterNumericsClass?) -> [ClusterDiagnosticsReport.Check] {
        let validation: DistributedInstalledValidation
        do {
            validation = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
        } catch let refusal as DistributedInstalledServingRefusal {
            return refused(refusal)
        } catch let refusal as ClusterPairServingRefusal {
            return refused(refusal)
        } catch {
            return [.init(name: "localInstalledMetadata", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(error))]
        }
        let metadata = ClusterDiagnosticsReport.Check(name: "localInstalledMetadata", outcome: .passed,
            detail: "Local worker hash, config/manifest/tokenizer pins, trust-file metadata/pin and installed runtime description verified. Weight payloads and SSH authentication were not tested.")
        do {
            try validation.plan.requireLocalRankGranted(numericsClass: localNumericsClass)
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
