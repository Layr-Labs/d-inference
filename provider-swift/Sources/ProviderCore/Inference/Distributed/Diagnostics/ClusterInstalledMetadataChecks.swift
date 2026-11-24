import Foundation

/// The doctor's check of this Mac's saved setup against its installation.
enum ClusterInstalledMetadataChecks {
    /// The release this Mac updated from: its version and the worker in its kept rollback copy.
    struct EarlierRelease: Sendable {
        let version: String
        let worker: URL
    }

    /// Runs the validation every start runs, then the owner's serving check
    /// for the rank this Mac runs, with `localChipClass` (this Mac's own class
    /// on a real Mac). A model no stage adapter runs, or a rank-shape that
    /// diverged, is reported as that, under `pairServingPolicy`, not as a
    /// metadata fault. A setup that differs only by naming `earlier`'s worker
    /// is a warning: the pair was set up before this Mac updated, and its next
    /// start sets it up again. So is one that differs only by pinning another
    /// worker while it names this build's own (`thisBuildsWorker`), signed like
    /// this provider (`signedWorker`): the pair stayed stopped across more than
    /// one update.
    static func localInstalledMetadata(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                                       deadline: UInt64, localChipClass: ClusterChipClass?,
                                       earlier: EarlierRelease? = nil, thisBuildsWorker: URL? = nil,
                                       signedWorker: (URL) -> Bool = { DistributedInstalledHelperSignature.current.signsWorker($0) })
        -> [ClusterDiagnosticsReport.Check] {
        let validation: DistributedInstalledValidation
        do {
            validation = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
        } catch let refusal as ClusterPairServingRefusal {
            return refused(refusal)
        } catch {
            if let earlier, DistributedInstalledValidation.pinsEarlierReleaseWorker(reference: reference, paths: paths,
                                                                                 earlier: earlier.worker, deadline: deadline) {
                return [.init(name: "localInstalledMetadata", outcome: .warning, detail: earlierWorkerDetail(earlier.version))]
            }
            if let thisBuildsWorker,
               DistributedInstalledValidation.pinsAnotherBuildsWorker(reference: reference, paths: paths, deadline: deadline,
                                                                      thisBuildsWorker: thisBuildsWorker, signedWorker: signedWorker) {
                return [.init(name: "localInstalledMetadata", outcome: .warning, detail: anotherBuildsWorkerDetail)]
            }
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

    static func earlierWorkerDetail(_ version: String) -> String {
        "The pair's saved setup still names the worker of Darkbloom \(version), the release this Mac updated from. "
            + "Its next start, once both Macs run this release, sets the pair up again with this release's worker. "
            + "The setup's other pinned files verified."
    }

    static let anotherBuildsWorkerDetail = "The pair's saved setup still pins another Darkbloom build's cluster worker, "
        + "as a pair left stopped while this Mac updated keeps it; the worker it names is this Darkbloom's own, signed with "
        + "the same certificate as this Darkbloom. Its next start, once both Macs run this release, sets the pair up again with this release's "
        + "worker. The setup's other pinned files verified."

    private static func refused(_ refusal: Error) -> [ClusterDiagnosticsReport.Check] {
        [.init(name: "pairServingPolicy", outcome: .failed, detail: ClusterDiagnosticsReport.boundedDetail(refusal)),
         .init(name: "localInstalledMetadata", outcome: .notRun,
               detail: "Not examined: this setup's model is not served on a pair.")]
    }
}
