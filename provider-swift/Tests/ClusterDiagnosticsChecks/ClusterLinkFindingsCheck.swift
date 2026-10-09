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
    }
}
