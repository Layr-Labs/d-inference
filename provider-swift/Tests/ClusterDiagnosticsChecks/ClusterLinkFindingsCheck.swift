import Foundation
@testable import InstalledContract

/// How a local link inspection appears among the doctor's checks. Reports are
/// built directly; the text readers and the child runner have their own checks
/// in `ClusterLinkChecks`.
extension ClusterDiagnosticsCheck {
    private typealias Link = ClusterLinkReadinessReport
    private typealias Outcome = ClusterDiagnosticsReport.Outcome

    private static func device(_ number: Int, _ verdict: ClusterLinkReadinessState, bridge: String? = nil) -> Link.Device {
        let active = verdict != .noActivePort
        return .init(device: "rdma_en\(number)", interface: "en\(number)", transport: .thunderbolt, portActive: active,
            interfaceActive: active, interfaceHasIPv4Address: verdict == .ready || verdict == .gidNotPublished,
            bridge: bridge, ipv4MappedGIDPresent: active ? verdict == .ready : nil, verdict: verdict)
    }

    private static func report(_ link: Link?, configuredDevice: String? = nil) -> ClusterDiagnosticsReport {
        .init(operation: link == nil ? "status" : "doctor", configurationState: .notConfigured, saved: nil, live: nil,
            deviceJournal: .absent, checks: [.init(name: "savedConfiguration", outcome: .notRun, detail: "fixture")],
            localLink: link, configuredLinkDevice: configuredDevice)
    }

    private static func requireChecks(_ report: ClusterDiagnosticsReport, _ expected: [(String, Outcome)], _ message: String) throws {
        let actual = report.checks.dropFirst().map { "\($0.name)=\($0.outcome.rawValue)" }
        try require(actual == expected.map { "\($0.0)=\($0.1.rawValue)" }, "\(message): \(actual)")
    }

    private static func detail(_ report: ClusterDiagnosticsReport, _ name: String) throws -> String {
        guard let check = report.checks.first(where: { $0.name == name }) else { throw Failure(message: "missing check \(name)") }
        return check.detail
    }

    static func linkFindings() throws {
        let macA = Link(state: .ready, devices: [device(2, .noActivePort), device(7, .ready)])
        let macB = Link(state: .portBridgedWithoutAddress,
            devices: [device(2, .noActivePort, bridge: "bridge0"), device(6, .portBridgedWithoutAddress, bridge: "bridge0")])
        let bridgedGuidance = ClusterLinkReadinessState.portBridgedWithoutAddress.guidance ?? ""

        // `cluster status` runs no link inspection and says so.
        let status = report(nil)
        try require(status.checks.map(\.name) == ["savedConfiguration"] && !status.localLinkInspectionPerformed, "status gained link checks")

        let ready = report(macA)
        try requireChecks(ready, [("localLink", .passed), ("localLinkDevice.rdma_en7", .passed)], "Mac A checks")
        try require(ready.localLinkInspectionPerformed && !ready.physicalProbePerformed && !ready.recoveryPerformed,
            "a local link inspection must not be reported as a physical probe")
        try require(try detail(ready, "localLink").hasPrefix("ready: ") && detail(ready, "localLink").contains("no collective ran"),
            "ready detail must state its scope")
        try require(try detail(ready, "localLinkDevice.rdma_en7")
            == "rdma_en7 (en7): ready · port active · own IPv4 address · IPv4-mapped GID published.", "ready device detail")
        let encoded = String(decoding: try JSONEncoder().encode(ready), as: UTF8.self)
        try require(encoded.contains("\"localLinkInspectionPerformed\":true") && encoded.contains("\"physicalProbePerformed\":false"),
            "doctor JSON honesty fields")

        let blocked = report(macB)
        try requireChecks(blocked, [("localLink", .failed), ("localLinkDevice.rdma_en6", .failed)], "Mac B checks")
        try require(try detail(blocked, "localLink") == "portBridgedWithoutAddress: " + bridgedGuidance, "Mac B guidance")
        try require(try detail(blocked, "localLinkDevice.rdma_en6") == "rdma_en6 (en6): portBridgedWithoutAddress · port active · "
            + "member of bridge0 · no IPv4 address of its own · no IPv4-mapped GID. " + bridgedGuidance, "Mac B device detail")

        // An address Darkbloom assigned to the port that the port does not
        // have: the doctor says so and names the one command, for the Mac and
        // for the port.
        var lostPort = device(6, .portBridgedWithoutAddress, bridge: "bridge0")
        lostPort.assignedAddress = .missing
        let lost = report(Link(state: .portBridgedWithoutAddress, devices: [device(2, .noActivePort, bridge: "bridge0"), lostPort]))
        let lostGuidance = ClusterLinkReadinessReport.addressLostGuidance
        try requireChecks(lost, [("localLink", .failed), ("localLinkDevice.rdma_en6", .failed)], "lost address checks")
        try require(try detail(lost, "localLink") == "portBridgedWithoutAddress: " + lostGuidance
            && lostGuidance.contains("run `darkbloom cluster`"), "lost address guidance for the Mac")
        try require(try detail(lost, "localLinkDevice.rdma_en6") == "rdma_en6 (en6): portBridgedWithoutAddress · port active · "
            + "member of bridge0 · no IPv4 address of its own · no IPv4-mapped GID · its recorded address is missing. "
            + lostGuidance, "lost address detail for the port")

        // Ready, but with an address nothing would put back: the doctor
        // passes and still says what to run before the address is lost.
        var temporaryPort = device(6, .ready, bridge: "bridge0")
        temporaryPort.assignedAddress = .present
        temporaryPort.addressKept = false
        let temporary = report(Link(state: .ready, devices: [temporaryPort]))
        let temporaryGuidance = ClusterLinkReadinessReport.addressTemporaryGuidance
        try requireChecks(temporary, [("localLink", .passed), ("localLinkDevice.rdma_en6", .passed)], "temporary address checks")
        try require(try detail(temporary, "localLink") == "ready: an active RDMA port publishes the IPv4-mapped GID that JACCL requires. "
            + temporaryGuidance + " Local interface state only: no peer was contacted and no collective ran."
            && temporaryGuidance.contains("run `darkbloom cluster`"), "temporary address guidance for the Mac")
        try require(try detail(temporary, "localLinkDevice.rdma_en6") == "rdma_en6 (en6): ready · port active · member of bridge0 · "
            + "own IPv4 address · IPv4-mapped GID published · nothing keeps its address. " + temporaryGuidance,
            "temporary address detail for the port")
        var keptPort = temporaryPort
        keptPort.addressKept = true
        try require(try detail(report(Link(state: .ready, devices: [keptPort])), "localLink") == detail(ready, "localLink"),
            "a kept address reads like any ready link")

        for state in [ClusterLinkReadinessState.rdmaDisabled, .rdmaUnavailable, .probeFailed] {
            let machine = report(Link(state: state), configuredDevice: "rdma_en7")
            try requireChecks(machine, [("localLink", .failed)], "\(state) checks")
            try require(try detail(machine, "localLink") == "\(state.rawValue): \(state.guidance ?? "")", "\(state) guidance")
        }
        try requireChecks(report(Link(state: .noActivePort, devices: [device(2, .noActivePort), device(7, .noActivePort)])),
            [("localLink", .failed)], "no active port checks")

        // A blocked port fails the doctor only when it is the one serving would use.
        let mixed = Link(state: .ready, devices: [device(6, .portBridgedWithoutAddress, bridge: "bridge0"), device(7, .ready)])
        try requireChecks(report(mixed), [("localLink", .passed), ("localLinkDevice.rdma_en6", .notObserved),
            ("localLinkDevice.rdma_en7", .passed)], "an unused blocked port")
        try requireChecks(report(mixed, configuredDevice: "rdma_en7"), [("localLink", .passed),
            ("localLinkDevice.rdma_en6", .notObserved), ("localLinkDevice.rdma_en7", .passed)], "saved setup on the ready port")
        let misplaced = report(mixed, configuredDevice: "rdma_en6")
        try requireChecks(misplaced, [("localLink", .passed), ("localLinkDevice.rdma_en6", .failed),
            ("localLinkDevice.rdma_en7", .passed)], "saved setup on the blocked port")
        try require(try detail(misplaced, "localLinkDevice.rdma_en6").contains(". The saved setup uses this device. " + bridgedGuidance),
            "saved-setup device detail")
        try require(try detail(misplaced, "localLinkDevice.rdma_en7").hasSuffix("IPv4-mapped GID published."), "other device detail")

        let unplugged = report(macA, configuredDevice: "rdma_en2")
        try requireChecks(unplugged, [("localLink", .passed), ("localLinkDevice.rdma_en2", .failed),
            ("localLinkDevice.rdma_en7", .passed)], "saved setup on a port that is down")
        try require(try detail(unplugged, "localLinkDevice.rdma_en2").hasSuffix(ClusterLinkReadinessState.noActivePort.guidance ?? "?"),
            "down-port guidance")

        // A name the Mac does not list is never echoed: the saved label syntax also admits dotted text.
        for unlisted in ["rdma_en9", "192.0.2.10"] {
            let missing = report(macA, configuredDevice: unlisted)
            try requireChecks(missing, [("localLink", .passed), ("localLinkDevice.rdma_en7", .passed),
                ("configuredLinkDevice", .failed)], "saved setup naming an unlisted device")
            try require(try !detail(missing, "configuredLinkDevice").contains(unlisted)
                && detail(missing, "configuredLinkDevice").contains("Darkbloom will not"), "unlisted device detail")
        }

        // Link setup v2: where the network around a port was read, the doctor
        // says whether it is isolated. A ready port that is not fails where
        // serving would use it, because it can lose its address mid-session.
        var exposed = device(7, .ready)
        exposed.isolation = ClusterLinkIsolationStatus(findings: [.defaultRouteViaPort, .dnsViaPort, .dhcpLeaseOnPort,
            .clusterServiceMissing, .otherServiceOnPort], hardwarePort: "Thunderbolt 6", otherServices: ["Thunderbolt 6"])
        let exposedReport = report(Link(state: .ready, devices: [device(2, .noActivePort), exposed]))
        try requireChecks(exposedReport, [("localLink", .passed), ("localLinkDevice.rdma_en7", .passed),
            ("localLinkIsolation.rdma_en7", .failed)], "a ready port that is not isolated")
        try require(try detail(exposedReport, "localLinkIsolation.rdma_en7").hasPrefix(
            "defaultRouteViaPort, dnsViaPort, dhcpLeaseOnPort, clusterServiceMissing, otherServiceOnPort: The cluster port en7 is not isolated")
            && detail(exposedReport, "localLinkIsolation.rdma_en7").contains("run `darkbloom cluster`"), "isolation detail names the findings and the fix")
        try require(try detail(exposedReport, "localLink").contains("not isolated"), "the Mac's guidance leads with the isolation")
        try require(try !detail(exposedReport, "localLinkIsolation.rdma_en7").contains("Thunderbolt 6"), "service names stay out")
        var isolatedPort = device(7, .ready)
        isolatedPort.isolation = ClusterLinkIsolationStatus(findings: [])
        let isolatedReport = report(Link(state: .ready, devices: [isolatedPort]))
        try requireChecks(isolatedReport, [("localLink", .passed), ("localLinkDevice.rdma_en7", .passed),
            ("localLinkIsolation.rdma_en7", .passed)], "an isolated port")
        try require(try detail(isolatedReport, "localLinkIsolation.rdma_en7").hasPrefix("Isolated: Thunderbolt port en7 has its own network service"),
            "isolated detail")
        var blockedPort = device(6, .ready, bridge: "bridge0")
        blockedPort.isolation = ClusterLinkIsolationStatus(findings: [.portInBridge, .internetSharingOverPortBridge, .internetSharingToPort,
            .clusterServiceMissing], bridge: "bridge0", hardwarePort: "Thunderbolt 2")
        let sharing = report(Link(state: .ready, devices: [blockedPort, isolatedPort]), configuredDevice: "rdma_en7")
        try requireChecks(sharing, [("localLink", .passed), ("localLinkDevice.rdma_en6", .passed), ("localLinkIsolation.rdma_en6", .notObserved),
            ("localLinkDevice.rdma_en7", .passed), ("localLinkIsolation.rdma_en7", .passed)], "an exposed port serving does not use")
        try require(try detail(sharing, "localLinkIsolation.rdma_en6").contains("Darkbloom does not change Internet Sharing")
            && detail(sharing, "localLinkIsolation.rdma_en6").contains("“Thunderbolt 2” (en6)"), "the owner's step for Internet Sharing")
    }
}
