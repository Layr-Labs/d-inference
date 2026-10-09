import Foundation

/// Reads this Mac's RDMA and interface state and says whether JACCL could
/// initialise on it. It changes no setting, contacts no peer, runs no
/// collective and logs nothing.
public enum ClusterLinkReadinessProbe {
    /// More RDMA devices than any Mac has ports; a longer listing is not trusted.
    private static let maximumDevices = 32
    private static let maximumOutputBytes = 256 * 1024
    private static let childTimeoutNanoseconds: UInt64 = 3_000_000_000
    /// Every child together, however many ports are active.
    private static let inspectionTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// Runs the fixed system tools. Blocking: at most `inspectionTimeoutNanoseconds`.
    public static func inspectLocalLink() -> ClusterLinkReadinessReport {
        // The owner-only record says which ports Darkbloom has addressed; a
        // record that cannot be read only means that is not reported.
        let recorded = (try? ClusterUserPaths()).flatMap { try? ClusterLinkAliasStore(paths: $0).load() }
        return inspect(run: boundedToolRunner(), recorded: recorded ?? ClusterLinkAliasRecord())
    }

    /// The live runner for one inspection: each child gets
    /// `childTimeoutNanoseconds`, and all of them together
    /// `inspectionTimeoutNanoseconds` counted from this call.
    static func boundedToolRunner() -> ClusterLinkToolRunner {
        let inspectionDeadline = DispatchTime.now().uptimeNanoseconds + inspectionTimeoutNanoseconds
        return { command in
            ClusterLinkToolProcess.run(executable: command.executable, arguments: command.arguments,
                deadline: min(DispatchTime.now().uptimeNanoseconds + childTimeoutNanoseconds, inspectionDeadline),
                maximumOutputBytes: maximumOutputBytes)
        }
    }

    /// The inspection over any runner, so that checks supply canned tool
    /// results and never start the real tools. `recorded` is what Darkbloom
    /// has assigned to ports before, so that a missing address of its own is
    /// told apart from none, and an address nothing keeps from one that lasts.
    static func inspect(run: ClusterLinkToolRunner,
                        recorded: ClusterLinkAliasRecord = ClusterLinkAliasRecord()) -> ClusterLinkReadinessReport {
        do {
            let devices = try inspectDevices(run: run, recorded: recorded)
            return .init(state: overallState(of: devices), devices: devices)
        } catch {
            return .init(state: error.state)
        }
    }

    /// A machine-level finding that ends the inspection before devices are judged.
    private struct Stopped: Error { let state: ClusterLinkReadinessState }

    private static func inspectDevices(run: ClusterLinkToolRunner,
                                       recorded: ClusterLinkAliasRecord) throws(Stopped) -> [ClusterLinkReadinessReport.Device] {
        switch ClusterRDMAToolOutput.controlState(try text(run(.rdmaControlStatus), whenUnavailable: .rdmaUnavailable)) {
        case .enabled: break
        case .disabled: throw Stopped(state: .rdmaDisabled)
        case nil: throw Stopped(state: .probeFailed)
        }
        // Without any RDMA device `ibv_devinfo` exits non-zero, which is unavailability.
        let listing = try text(run(.rdmaDeviceList), whenUnavailable: .rdmaUnavailable)
        guard let devices = ClusterRDMAToolOutput.devices(listing), devices.count <= maximumDevices else {
            throw Stopped(state: .probeFailed)
        }
        let interfaceListing = try text(run(.interfaceList), whenUnavailable: .probeFailed)
        guard let interfaces = ClusterNetworkInterfaces.parse(interfaceListing) else {
            throw Stopped(state: .probeFailed)
        }
        return devices.map { device in
            var gidPresent: Bool?
            if device.portActive, case .output(let detail) = run(.rdmaDeviceDetail(device: device.name)) {
                gidPresent = ClusterRDMAToolOutput.ipv4MappedGIDPresent(inDetail: detail, of: device.name)
            }
            var judgement = judged(device, interfaces: interfaces, ipv4MappedGIDPresent: gidPresent)
            // Only a port Darkbloom has on record costs the two extra readings.
            if let alias = judgement.interface.flatMap(recorded.alias(on:)) {
                let carried = ClusterNetworkInterfaces.lists(alias.address, on: alias.interface, inListing: interfaceListing) == true
                judgement.assignedAddress = carried ? .present : .missing
                judgement.addressKept = ClusterLinkAddressKeeper(interface: alias.interface, address: alias.address)?
                    .isRunning(run: run)
            }
            return judgement
        }
    }

    private static func text(_ outcome: ClusterLinkToolOutcome,
                             whenUnavailable state: ClusterLinkReadinessState) throws(Stopped) -> String {
        switch outcome {
        case .output(let text): return text
        case .unavailable: throw Stopped(state: state)
        case .timedOut, .outputTooLarge: throw Stopped(state: .probeFailed)
        }
    }

    private static func judged(_ device: ClusterRDMAToolOutput.Device, interfaces: ClusterNetworkInterfaces,
                               ipv4MappedGIDPresent: Bool?) -> ClusterLinkReadinessReport.Device {
        let interfaceName = ClusterLinkName.interface(ofDevice: device.name)
        let interface = interfaceName.flatMap(interfaces.interface(named:))
        let bridge = interfaceName.flatMap(interfaces.bridge(containing:))
        return .init(device: device.name, interface: interfaceName, transport: device.transport,
            portActive: device.portActive, interfaceActive: interface.map { $0.isUp && $0.linkActive },
            interfaceHasIPv4Address: interface?.hasIPv4Address, bridge: bridge,
            ipv4MappedGIDPresent: ipv4MappedGIDPresent,
            verdict: verdict(portActive: device.portActive, ipv4MappedGIDPresent: ipv4MappedGIDPresent,
                interfaceHasIPv4Address: interface?.hasIPv4Address, bridged: bridge != nil))
    }

    /// The published GID is what JACCL checks, so it alone decides readiness;
    /// the interface facts only explain why a GID is missing.
    private static func verdict(portActive: Bool, ipv4MappedGIDPresent: Bool?, interfaceHasIPv4Address: Bool?,
                                bridged: Bool) -> ClusterLinkReadinessState {
        guard portActive else { return .noActivePort }
        guard let ipv4MappedGIDPresent else { return .probeFailed }
        if ipv4MappedGIDPresent { return .ready }
        guard interfaceHasIPv4Address == false else { return .gidNotPublished }
        return bridged ? .portBridgedWithoutAddress : .portWithoutIPv4Address
    }

    /// One ready port is enough. Otherwise the first active port, in listing
    /// order, names what to fix.
    private static func overallState(of devices: [ClusterLinkReadinessReport.Device]) -> ClusterLinkReadinessState {
        let active = devices.filter(\.portActive)
        if active.contains(where: { $0.verdict == .ready }) { return .ready }
        return active.first?.verdict ?? .noActivePort
    }
}
