import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation

/// `darkbloom cluster pair`, as plain values so the command target needs only
/// ProviderCore. See `Cluster.Pair` for the user's view.
public struct ClusterPairCommandRequest: Sendable {
    public var connect: String?
    public var interface: String?
    public var device: String?
    public var localAddress: String?
    public var port: Int = Int(ClusterCablePorts.current.pairing)
    public var clusterID: String?
    /// Only listen (answering probes): no search first, never dial. Default
    /// without `connect`: find the other Mac on the cable, or wait for it.
    public var listenOnly = false
    public var loopbackForTests = false
    public var lifetimeSeconds: Double = ClusterPairingPolicy.codeLifetimeSeconds

    public init() {}

    /// A problem with the options, or nil.
    public func problem() -> String? {
        guard (1024...65_535).contains(port) else { return "--port must be 1024...65535." }
        if let connect, ClusterLinkIPv4Address(connect) == nil { return "--connect takes the IPv4 address the other Mac printed." }
        if listenOnly, connect != nil { return "Choose --listen or --connect, not both." }
        if let localAddress, ClusterLinkIPv4Address(localAddress) == nil { return "--local-address must be an IPv4 address." }
        if let clusterID, !ClusterPairingLabel.isValid(clusterID) { return "--cluster-id takes letters, digits, '-', '.' and '_' (at most 128)." }
        guard lifetimeSeconds > 0, lifetimeSeconds <= ClusterPairingPolicy.codeLifetimeSeconds else {
            return "--lifetime-seconds is at most \(Int(ClusterPairingPolicy.codeLifetimeSeconds))."
        }
        return nil
    }
}

public enum ClusterPairCommandLine {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    /// This install's pairing port (`ClusterCablePorts`): production's 47421.
    public static var defaultPort: Int { Int(ClusterCablePorts.current.pairing) }
    public static func isPin(_ value: String) -> Bool { ClusterPairingPin.isPin(value) }

    /// Runs the ceremony on this terminal; true when the Macs are paired.
    public static func pair(_ request: ClusterPairCommandRequest, store: ClusterPairingStore = .default()) throws -> Bool {
        if let problem = request.problem() { throw Failure(description: problem) }
        guard ClusterPairingTerminal.isTerminal() else {
            throw Failure(description: "Pairing needs a person at a terminal on this Mac: both screens show a code to compare.")
        }
        let identity: any ClusterPairingIdentity
        do { identity = try ClusterPairingProvider.identity() } catch { throw Failure(description: "\(error)") }
        let peer = request.connect.flatMap(ClusterLinkIPv4Address.init)
        let interface = try resolveInterface(request, peer: peer)
        let chipName = (try? HardwareDetector.detect().chipName) ?? "Mac"
        let participant = ClusterPairingProvider.participant(identity: identity, chipName: chipName, interface: interface,
            store: store, clusterID: request.clusterID)
        var options = ClusterLinkPairing.Options(role: peer == nil ? .listener : .connector, interface: interface,
            localAddress: request.localAddress.flatMap(ClusterLinkIPv4Address.init), peerAddress: peer)
        options.port = UInt16(request.port)
        options.policy = request.loopbackForTests ? .loopbackForTests : .thunderboltOnly
        options.lifetimeSeconds = request.lifetimeSeconds
        if peer == nil { options.discovery = request.listenOnly ? .answer : .find }
        let terminal = ClusterPairingTerminal()
        terminal.say("Pairing over the Thunderbolt link: no SSH, no password, nothing to type but y or n.")
        terminal.say("This Mac:       \(ClusterPairingProvider.displayName(chipName: chipName)); Secure Enclave key pin "
            + "\(ClusterPairingPin.of(identityKey: identity.identityPublicKey).prefix(16))…")
        let policy = options.policy, local = options.localAddress
        let callbacks = terminal.callbacks { interface, port in
            guard let selection = try? ClusterLinkInterfaceAdmission.select(interface: interface, localAddress: local,
                peerAddress: nil, policy: policy, inspector: ClusterLinkSystemInterfaceInspector()) else { return nil }
            let portText = port == ClusterCablePorts.current.pairing ? "" : " --port \(port)"
            // This build's command: the other app's `cluster pair` pairs that app, on its own port, and never finds this Mac.
            let cli = BuildEnvironment.current.cliName
            return "\(cli) cluster pair\(portText)   (it finds this Mac; if not: \(cli) cluster pair --connect "
                + "\(selection.local.address.dottedDecimal)\(portText))"
        }
        let result = ClusterLinkPairing.run(options: options, participant: participant, hooks: ClusterPairingProvider.hooks,
            store: store, callbacks: callbacks)
        terminal.restoreMode()
        for line in ClusterPairingTerminal.summary(result) { terminal.say(line) }
        if case .success = result { return true }
        return false
    }

    static func resolveInterface(_ request: ClusterPairCommandRequest, peer: ClusterLinkIPv4Address?) throws -> String {
        if request.loopbackForTests { return "lo0" }
        if let interface = request.interface { return interface }
        if let device = request.device {
            guard let carrier = ClusterLinkControlHost.listenInterface(forDevice: device, reaching: peer) else {
                throw Failure(description: "\(device) has no interface carrying IPv4 (check `\(BuildEnvironment.current.cliName) cluster link`).")
            }
            return carrier
        }
        // The cable's active RDMA port, as `darkbloom cluster link` reads it, then its interface or bridge.
        let link = ClusterLinkReadinessProbe.inspectLocalLink(isolation: false)
        let active = link.devices.filter(\.portActive)
        if let device = (active.first { $0.verdict == .ready } ?? active.first)?.device,
           let carrier = ClusterLinkControlHost.listenInterface(forDevice: device, reaching: peer) {
            return carrier
        }
        guard let automatic = ClusterLinkPairing.automaticInterface(reaching: peer) else {
            throw Failure(description: "Name the link interface with --interface (or --device rdma_enN): no active RDMA port carries IPv4, and this Mac has none, or several, Thunderbolt interfaces with IPv4.")
        }
        return automatic
    }

    /// `--status`: the lines to print, or the records as JSON.
    public static func status(json: Bool, store: ClusterPairingStore = .default()) throws -> String {
        let records = try store.load()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let value = records ?? ClusterPairingRecords(localPin: "", localIdentityKey: "", pairings: [])
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        guard let records else { return "This Mac has not paired with another Mac." }
        var lines = ["This Mac's pin \(records.localPin.prefix(16))…; \(records.pairings.count) pairing\(records.pairings.count == 1 ? "" : "s"):"]
        for record in records.pairings {
            lines.append("  \(record.peerPin.prefix(16))…  \(record.peerName)  paired \(record.pairedAt) as \(record.role.rawValue)")
            lines.append("      roster \(record.clusterID) generation \(record.roster.generation) sha256 \(record.rosterSHA256.prefix(16))…; "
                + "link \(record.link.localInterface) to \(record.link.peerInterface)")
            lines.append("      link key " + linkKeyWords(store.linkKeyLocation(for: record)))
        }
        return lines.joined(separator: "\n")
    }

    /// Where a pairing's link key is, as `--status` says it (never the key).
    static func linkKeyWords(_ location: ClusterPairingStore.LinkKeyLocation) -> String {
        switch location {
        case .keychain(let protection, let legacyFileLeft):
            let kept = protection.afterFirstUnlockThisDeviceOnly ? "this Mac only, readable after its first unlock, not synchronised"
                : "kept as \(protection.accessible ?? "unknown")\(protection.synchronizable ? ", synchronised" : "")"
            return "in this Mac's Keychain (\(kept); access group \(protection.accessGroup ?? "unknown"))"
                + (legacyFileLeft ? "; an earlier release's key file is still beside it and goes at the next start" : "; no key file")
        case .file: return "in its owner-only file (this build keeps no Keychain items, or it moves there at the next use)"
        case .missing: return "gone: the Macs must pair again"
        case .keychainLocked: return "in this Mac's Keychain, which is locked until someone logs in to this Mac"
        case .keychainUnavailable(let status): return "unknown: the Keychain did not answer (OSStatus \(status))"
        }
    }

    /// `--forget PIN`: the lines to print for the pairing it removed (`ClusterUnpairing`).
    public static func forgotten(_ record: ClusterPairingRecord) -> String {
        "Unpaired from \(record.peerPin.prefix(16))… (\(record.peerName)); its pin and link key were removed.\n"
            + "A setup whose roster names it no longer starts here until the two Macs pair again."
    }
}
