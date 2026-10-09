import Foundation

extension ClusterLinkReadinessReport {
    /// The doctor's findings from a local link inspection: one check for the
    /// Mac as a whole, then one for each port that is active or that the saved
    /// setup uses. `configuredDevice` is the RDMA device the saved setup
    /// assigns to this Mac, when a setup is saved.
    ///
    /// A port that is not ready fails only where serving would use it: the
    /// saved setup's port, or any active port when nothing is saved and none
    /// is ready. Elsewhere its readiness is reported as not observed.
    func diagnosticChecks(configuredDevice: String?) -> [ClusterDiagnosticsReport.Check] {
        var checks = [ClusterDiagnosticsReport.Check(name: "localLink", outcome: state == .ready ? .passed : .failed,
            detail: "\(state.rawValue): " + (guidance ?? "an active RDMA port publishes the IPv4-mapped GID that JACCL requires. " + Self.readyScope))]
        for device in devices where device.portActive || device.device == configuredDevice {
            let configured = device.device == configuredDevice
            let servingWouldUseIt = configured || (configuredDevice == nil && state != .ready)
            let detail = [device.summary + ".", configured ? "The saved setup uses this device." : nil, device.verdict.guidance]
            checks.append(.init(name: "localLinkDevice.\(device.device)",
                outcome: device.verdict == .ready ? .passed : servingWouldUseIt ? .failed : .notObserved,
                detail: detail.compactMap { $0 }.joined(separator: " ")))
        }
        // The saved name is not echoed: its syntax is wider than a device name.
        if configuredDevice != nil, !devices.isEmpty, !devices.contains(where: { $0.device == configuredDevice }) {
            checks.append(.init(name: "configuredLinkDevice", outcome: .failed,
                detail: "The saved setup names an RDMA device that this Mac does not list; correct the device name in the cluster setup or move the cable to the port it names, because Darkbloom will not change either for you."))
        }
        return checks
    }
}
