import Foundation
import ProviderCore

// Seams for the red tests of `darkbloom doctor`'s Local API section, with today's behaviour: doctor says nothing of
// how this Mac serves you, its local API or the tools, and runs the Darkbloom network's checks on every Mac.

struct DoctorLocalAPI {
    struct Facts {
        var saved: LocalSettings?
        var running: DaemonState?
        var live: LocalEndpoint.Info?
        var answers: Bool?
        var keyFile: URL?
        var pair: ClusterPairSummary = .notPaired
        var tools: [DoctorToolSetup] = []
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        var nextFreePort: (UInt16) -> UInt16? = { _ in nil }
    }

    let facts: Facts

    var mode: LocalSettings.Mode? { nil }
    var onlyMe: Bool { false }
    var diagnostics: [Diagnostic] { [] }
    func lines(networkChecks: Bool) -> [Diagnostic] { [] }

    static let networkNotNeeded = DoctorCheck(name: "darkbloom network", status: .pass, detail: "")
}
