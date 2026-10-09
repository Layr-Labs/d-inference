import Foundation

/// What an earlier link fix has left on this Mac for one port: the address
/// itself and the two parts of the job that keeps it there. Removal undoes
/// exactly what is found here, and a record entry is spent once nothing is.
struct ClusterLinkFixRemnants: Equatable, Sendable {
    var address = false
    /// The keeper is loaded in launchd.
    var keeperJob = false
    /// The keeper's job definition exists under `/Library/LaunchDaemons`.
    var keeperFile = false

    var isEmpty: Bool { !address && !keeperJob && !keeperFile }

    /// Read with three read-only tools. Nil when one of them could not answer.
    /// The job definition counts as there when a file has its name, whatever
    /// the file holds and whoever may read it.
    static func observed(interface: String, address: ClusterLinkLocalAddress,
                         run: ClusterLinkToolRunner) -> ClusterLinkFixRemnants? {
        guard case .output(let listing) = run(.interfaceList),
              let carried = ClusterNetworkInterfaces.lists(address, on: interface, inListing: listing),
              let loaded = loaded(run(.keeperJob(interface: interface))),
              case .output(let files) = run(.keeperJobFileList) else { return nil }
        return ClusterLinkFixRemnants(address: carried, keeperJob: loaded,
            keeperFile: ClusterLinkAddressKeeper.installedInterfaces(inListing: files).contains(interface))
    }

    /// `launchctl print` exits 0 for a loaded job and non-zero for one that
    /// is not; a run that could not finish says neither.
    private static func loaded(_ outcome: ClusterLinkToolOutcome) -> Bool? {
        switch outcome {
        case .output: return true
        case .unavailable: return false
        case .timedOut, .outputTooLarge: return nil
        }
    }
}
