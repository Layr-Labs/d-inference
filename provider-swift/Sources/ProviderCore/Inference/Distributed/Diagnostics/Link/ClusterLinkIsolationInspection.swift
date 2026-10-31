import Foundation

/// Reads, without any privilege, how the network around a cluster port is
/// put together, and judges it against link setup v2. Like the readiness
/// probe it changes nothing, contacts no peer and keeps only names and
/// yes/no answers.
enum ClusterLinkIsolationInspection {
    /// The machine-wide readings, taken once per inspection.
    struct Machine: Equatable, Sendable {
        let hardwarePorts: [String: String]
        let services: [ClusterLinkNetworkFacts.Service]
        let preferenceBridges: [String: [String]]
        let sharingEnabled: Bool
        let sharingDevices: [String]
        let defaultRouteInterfaces: [String]
        let clusterSubnetRouteInterfaces: [String]
        let dnsInterfaces: [String]
    }

    /// Nil when one reading timed out, overflowed, or printed text of the
    /// wrong shape. A tool that exits non-zero where that means "none" (no
    /// Internet Sharing file, no bridge key) is an empty answer, not a failure.
    static func machine(run: ClusterLinkToolRunner) -> Machine? {
        /// A reading that must succeed.
        func required(_ command: ClusterLinkToolCommand) -> String? {
            guard case .output(let text) = run(command) else { return nil }
            return text
        }
        /// A reading whose non-zero exit means "there is none": `parse` of
        /// the text, `empty` when absent, nil when it failed or is garbled.
        func optional<Value>(_ command: ClusterLinkToolCommand, empty: Value, _ parse: (String) -> Value?) -> Value? {
            switch run(command) {
            case .output(let text): return parse(text)
            case .unavailable: return empty
            case .timedOut, .outputTooLarge: return nil
            }
        }
        guard let ports = required(.hardwarePorts),
              let services = required(.networkServiceOrder).flatMap(ClusterLinkNetworkFacts.services),
              let bridges = optional(.bridgePreferences, empty: [:], ClusterLinkNetworkFacts.preferenceBridges),
              let enabled = optional(.internetSharingEnabled, empty: false, ClusterLinkNetworkFacts.sharingEnabled),
              let devices = optional(.internetSharingDevices, empty: [], ClusterLinkNetworkFacts.sharingDevices),
              let routes = required(.routeTable),
              let defaults = ClusterLinkNetworkFacts.defaultRouteInterfaces(routes),
              let subnetRoutes = ClusterLinkNetworkFacts.clusterSubnetRouteInterfaces(routes),
              let resolvers = required(.dnsConfiguration).flatMap(ClusterLinkNetworkFacts.dnsInterfaces) else { return nil }
        return Machine(hardwarePorts: ClusterLinkNetworkFacts.hardwarePorts(ports), services: services,
            preferenceBridges: bridges, sharingEnabled: enabled, sharingDevices: devices,
            defaultRouteInterfaces: defaults, clusterSubnetRouteInterfaces: subnetRoutes, dnsInterfaces: resolvers)
    }

    /// The judgement for one port. `interfaceListing` is the `ifconfig -a`
    /// text the readiness probe has already read; `expected` is the address
    /// Darkbloom recorded for the port, when it has one. Two more readings
    /// are taken here: the port's DHCP lease and Darkbloom's service.
    static func status(interface: String, interfaceListing: String, machine: Machine?,
                       expected: ClusterLinkClusterAddress?, run: ClusterLinkToolRunner) -> ClusterLinkIsolationStatus {
        guard let machine, let interfaces = ClusterNetworkInterfaces.parse(interfaceListing) else {
            return .init(findings: [.stateUnreadable])
        }
        var findings = [ClusterLinkIsolationFinding]()
        let kernelBridge = interfaces.bridge(containing: interface)
        let preference = machine.preferenceBridges.sorted { $0.key < $1.key }
            .first { $0.value.contains(interface) }
            .map { ClusterLinkIsolationStatus.BridgeMembership(bridge: $0.key, index: $0.value.firstIndex(of: interface)!, members: $0.value) }
        if let preference {
            findings.append(.portInBridge)
            if machine.sharingEnabled, machine.sharingDevices.contains(preference.bridge) {
                findings.append(.internetSharingOverPortBridge)
            }
        } else if kernelBridge != nil {
            findings.append(.portInUnmanagedBridge)
        }
        if machine.sharingEnabled, machine.sharingDevices.contains(interface) { findings.append(.internetSharingToPort) }
        if machine.defaultRouteInterfaces.contains(interface) { findings.append(.defaultRouteViaPort) }
        if machine.dnsInterfaces.contains(interface) { findings.append(.dnsViaPort) }
        if case .output(let packet) = run(.dhcpPacket(interface: interface)), ClusterLinkNetworkFacts.holdsDHCPLease(packet) {
            findings.append(.dhcpLeaseOnPort)
        }
        if interfaces.interface(named: interface)?.hasIPv4Address != true { findings.append(.portAddressMissing) }

        let ours = ClusterLinkServiceName.cluster(interface: interface)
        let onPort = machine.services.filter { $0.interface == interface }
        let clusterService = onPort.first { $0.name == ours }
        if let clusterService {
            if !clusterService.enabled || !configuredAsWritten(service: ours, expected: expected, run: run) {
                findings.append(.clusterServiceMisconfigured)
            }
        } else {
            findings.append(.clusterServiceMissing)
        }
        let others = onPort.filter { $0.enabled && $0.name != ours }.map(\.name)
        if !others.isEmpty { findings.append(.otherServiceOnPort) }

        // What the approval would need to do safely.
        let subnetElsewhere = !ClusterLinkNetworkFacts.interfacesInClusterSubnet(interfaceListing, except: interface).isEmpty
            || machine.clusterSubnetRouteInterfaces.contains { $0 != interface }
        if subnetElsewhere { findings.append(.clusterSubnetInUse) }
        let hardwarePort = machine.hardwarePorts[interface]
        let needsService = clusterService == nil || findings.contains(.clusterServiceMisconfigured)
        if needsService, hardwarePort == nil { findings.append(.hardwarePortUnknown) }
        if !others.allSatisfy(ClusterLinkServiceName.isSafe) || (needsService && hardwarePort.map(ClusterLinkServiceName.isSafe) == false) {
            findings.append(.serviceNameUnsafe)
        }
        return .init(findings: findings, bridge: preference?.bridge ?? kernelBridge, preferenceBridge: preference,
            hardwarePort: hardwarePort, otherServices: others, clusterServicePresent: clusterService != nil)
    }

    /// Whether Darkbloom's service is manual, in the cluster subnet (on the
    /// recorded address when there is one), with the cluster netmask, no
    /// router and IPv6 other than automatic.
    private static func configuredAsWritten(service: String, expected: ClusterLinkClusterAddress?,
                                            run: ClusterLinkToolRunner) -> Bool {
        guard ClusterLinkServiceName.isSafe(service), case .output(let text) = run(.networkServiceInfo(service: service)),
              let info = ClusterLinkNetworkFacts.serviceInfo(text), info.manual, !info.router,
              let address = info.address, let parsed = ClusterLinkClusterAddress(dottedDecimal: address),
              info.subnetMask == ClusterLinkClusterAddress.netmask, info.ipv6 != "automatic" else { return false }
        return expected.map { $0 == parsed } ?? true
    }
}
