import Foundation
import Darwin

/// Which port `cluster link --fix` may act on. Pure: a report in, a decision out.
enum ClusterLinkFixPlan: Equatable {
    case act(device: String, interface: String)
    /// Several ports qualify; the operator must name one of these devices.
    case choose(among: [String])
    case stop(ClusterLinkRepairOutcome)

    /// Without `requested`, exactly one active port must lack an address, and
    /// a Mac that is already ready is left alone. With it, only that device
    /// is considered, and it must qualify in the same way. A name that is not
    /// in the report is never acted on.
    static func make(for report: ClusterLinkReadinessReport, device requested: String?) -> ClusterLinkFixPlan {
        guard !report.devices.isEmpty else { return .stop(.nothingFixable(report.state)) }
        let target: ClusterLinkReadinessReport.Device
        if let requested {
            guard let named = report.devices.first(where: { $0.device == requested }) else { return .stop(.deviceNotListed) }
            if named.verdict == .ready { return .stop(.alreadyReady) }
            target = named
        } else {
            if report.state == .ready { return .stop(.alreadyReady) }
            let fixable = report.devices.filter(lacksOnlyAnAddress)
            guard let only = fixable.first else { return .stop(.nothingFixable(report.state)) }
            guard fixable.count == 1 else { return .choose(among: fixable.map(\.device)) }
            target = only
        }
        // The names came from validated tool output; they are checked again
        // here because this is where a privileged command starts.
        guard lacksOnlyAnAddress(target), ClusterLinkName.isDevice(target.device),
              let interface = target.interface, ClusterLinkName.isInterface(interface) else {
            return .stop(.nothingFixable(target.verdict))
        }
        return .act(device: target.device, interface: interface)
    }

    /// The one condition the fix cures, for a chosen port and a named one alike.
    private static func lacksOnlyAnAddress(_ device: ClusterLinkReadinessReport.Device) -> Bool {
        device.portActive && device.verdict.fixableByAddingAddress
    }
}

/// `darkbloom cluster link --fix` and `--remove`: give one Thunderbolt port a
/// link-local address of its own, or take that address away again. The change
/// itself is one fixed `ifconfig` command that macOS runs only after the
/// person at the screen approves its authorization prompt.
public enum ClusterLinkRepair {
    /// Everything the flows touch outside themselves, so that checks can
    /// script a Mac without a child process, a prompt or a file.
    struct Environment {
        /// A fresh runner for one bounded round of reading state.
        var toolRunner: () -> ClusterLinkToolRunner
        var requestApproval: (ClusterLinkAliasCommand) -> ClusterLinkApprovalResult
        var machineIdentifier: () -> String?
        var loadRecord: () throws -> ClusterLinkAliasRecord
        /// Changes the record as it is on disk at that moment.
        var updateRecord: ((inout ClusterLinkAliasRecord) -> Void) throws -> Void
        /// Waits between two looks at a port whose GID has not appeared yet.
        var pause: () -> Void
    }

    /// The GID follows the address within moments. This many probes, one
    /// second apart, is the whole wait, and it is only spent in full when the
    /// GID never appears.
    static let verificationAttempts = 10
    private static let verificationIntervalMicroseconds: UInt32 = 1_000_000

    /// Whether text has the shape of an RDMA device name such as `rdma_en6`.
    public static func isDeviceName(_ text: String) -> Bool {
        ClusterLinkName.isDevice(text)
    }

    /// Blocking: waits for the person at the screen to answer the prompt.
    public static func fix(device: String?) -> ClusterLinkRepairResult {
        guard let environment = liveEnvironment() else { return .init(operation: .fix, outcome: .recordUnavailable) }
        return fix(device: device, in: environment)
    }

    /// Blocking: waits for the person at the screen to answer the prompt.
    public static func remove(device: String?) -> ClusterLinkRepairResult {
        guard let environment = liveEnvironment() else { return .init(operation: .remove, outcome: .recordUnavailable) }
        return remove(device: device, in: environment)
    }

    static func fix(device requested: String?, in environment: Environment) -> ClusterLinkRepairResult {
        let run = environment.toolRunner()
        let device: String, interface: String
        let report = ClusterLinkReadinessProbe.inspect(run: run)
        switch ClusterLinkFixPlan.make(for: report, device: requested) {
        case .stop(let outcome):
            // A stop about a named port says which port it is about.
            let named = report.devices.first { $0.device == requested }
            return .init(operation: .fix, outcome: outcome, device: named?.device, interface: named?.interface)
        case .choose(let candidates): return .init(operation: .fix, outcome: .ambiguousPorts, candidates: candidates)
        case .act(let plannedDevice, let plannedInterface): (device, interface) = (plannedDevice, plannedInterface)
        }
        func ended(_ outcome: ClusterLinkRepairOutcome, manualCommand: String? = nil) -> ClusterLinkRepairResult {
            .init(operation: .fix, outcome: outcome, device: device, interface: interface, manualCommand: manualCommand)
        }
        // Without a baseline there is nothing to verify the change against.
        guard let baseline = ClusterLinkTopology.observe(run: run) else { return ended(.nothingFixable(.probeFailed)) }
        guard let machine = environment.machineIdentifier() else { return ended(.machineIdentityUnavailable) }
        let address = ClusterLinkLocalAddress.derived(machineIdentifier: machine, interface: interface)
        // The plan has already validated the interface; the command type checks
        // it once more, because nothing unvalidated may reach the prompt.
        guard let command = ClusterLinkAliasCommand(action: .add, interface: interface, address: address) else {
            return ended(.nothingFixable(.probeFailed))
        }
        // Recorded before the prompt, so that no alias can exist that
        // `--remove` does not know about.
        let alias = ClusterLinkAliasRecord.Alias(interface: interface, address: address)
        guard (try? environment.updateRecord { $0.set(alias) }) != nil else { return ended(.recordUnavailable) }
        func forgetAliasUnlessPresent() {
            // The entry goes only once the port is seen without the address: a
            // command that reported an error may still have added it.
            guard case .output(let listing) = environment.toolRunner()(.interfaceList),
                  ClusterNetworkInterfaces.lists(address, on: interface, inListing: listing) == false else { return }
            try? environment.updateRecord { $0.forget(interface: interface) }
        }
        switch environment.requestApproval(command) {
        case .declined:
            forgetAliasUnlessPresent()
            return ended(.approvalDeclined)
        case .unavailable:
            // The entry stays: an address the administrator adds with the
            // manual command is then still this record's to remove.
            return ended(.approvalUnavailable, manualCommand: command.manualCommand)
        case .commandFailed:
            forgetAliasUnlessPresent()
            return ended(.commandFailed)
        case .applied:
            // Recorded again: while the prompt was open, another command that
            // did not see the address yet may have cleared the entry as spent.
            try? environment.updateRecord { $0.set(alias) }
            let unmet = unmetConditions(device: device, baseline: baseline, in: environment)
            return ended(unmet.isEmpty ? .fixed : .appliedButNotReady(unmet))
        }
    }

    static func remove(device requested: String?, in environment: Environment) -> ClusterLinkRepairResult {
        typealias Alias = ClusterLinkAliasRecord.Alias
        guard let record = try? environment.loadRecord() else { return .init(operation: .remove, outcome: .recordUnavailable) }
        let recorded: [Alias]
        if let requested {
            recorded = [ClusterLinkName.interface(ofDevice: requested).flatMap(record.alias(on:))].compactMap { $0 }
        } else {
            recorded = record.aliases
        }
        guard !recorded.isEmpty else { return .init(operation: .remove, outcome: .nothingRecorded) }
        func ended(_ outcome: ClusterLinkRepairOutcome, _ alias: Alias?, manualCommand: String? = nil) -> ClusterLinkRepairResult {
            .init(operation: .remove, outcome: outcome, device: alias.map { ClusterLinkName.device(ofInterface: $0.interface) },
                interface: alias?.interface, manualCommand: manualCommand)
        }
        /// The recorded aliases their ports still carry; nil when that cannot be read.
        func stillPresent(_ aliases: [Alias]) -> [Alias]? {
            guard case .output(let listing) = environment.toolRunner()(.interfaceList),
                  ClusterNetworkInterfaces.parse(listing) != nil else { return nil }
            return aliases.filter { ClusterNetworkInterfaces.lists($0.address, on: $0.interface, inListing: listing) == true }
        }
        func forget(_ aliases: [Alias]) {
            guard !aliases.isEmpty else { return }
            // An update that fails leaves a stale entry, which the next removal clears the same way.
            try? environment.updateRecord { record in aliases.forEach { record.forget(interface: $0.interface) } }
        }
        let onlyRecorded = recorded.count == 1 ? recorded.first : nil
        guard let present = stillPresent(recorded) else { return ended(.nothingFixable(.probeFailed), onlyRecorded) }
        // An address does not survive a restart or a replug: entries without one are spent.
        forget(recorded.filter { !present.contains($0) })
        guard let alias = present.first else { return ended(.alreadyAbsent, onlyRecorded) }
        guard present.count == 1 else {
            return .init(operation: .remove, outcome: .ambiguousPorts,
                candidates: present.map { ClusterLinkName.device(ofInterface: $0.interface) })
        }
        // A decoded record holds only validated names, and the command type checks again.
        guard let command = ClusterLinkAliasCommand(action: .remove, interface: alias.interface, address: alias.address) else {
            return ended(.recordUnavailable, alias)
        }
        switch environment.requestApproval(command) {
        case .declined: return ended(.approvalDeclined, alias)
        case .unavailable: return ended(.approvalUnavailable, alias, manualCommand: command.manualCommand)
        case .commandFailed: return ended(.commandFailed, alias)
        case .applied:
            guard stillPresent([alias])?.isEmpty == true else { return ended(.removalNotVerified, alias) }
            forget([alias])
            return ended(.removed, alias)
        }
    }

    /// The three things that must hold after the address is added: the port's
    /// device is ready, no bridge gained or lost a member, and the default
    /// route still leaves through the same interface.
    private static func unmetConditions(device: String, baseline: ClusterLinkTopology,
                                        in environment: Environment) -> [ClusterLinkRepairOutcome.Unmet] {
        var ready = false
        for attempt in 1...verificationAttempts {
            let report = ClusterLinkReadinessProbe.inspect(run: environment.toolRunner())
            ready = report.devices.first { $0.device == device }?.verdict == .ready
            if ready || attempt == verificationAttempts { break }
            environment.pause()
        }
        var unmet: [ClusterLinkRepairOutcome.Unmet] = ready ? [] : [.deviceNotReady]
        guard let topology = ClusterLinkTopology.observe(run: environment.toolRunner()) else { return unmet + [.stateUnreadable] }
        if topology.bridgeMembers != baseline.bridgeMembers { unmet.append(.bridgeMembersChanged) }
        if topology.defaultRouteInterface != baseline.defaultRouteInterface { unmet.append(.defaultRouteChanged) }
        return unmet
    }

    private static func liveEnvironment() -> Environment? {
        guard let paths = try? ClusterUserPaths() else { return nil }
        let store = ClusterLinkAliasStore(paths: paths)
        return Environment(toolRunner: ClusterLinkReadinessProbe.boundedToolRunner, requestApproval: ClusterLinkApproval.request,
            machineIdentifier: ClusterLinkMachineIdentity.hardwareUUID, loadRecord: store.load, updateRecord: store.update,
            pause: { usleep(verificationIntervalMicroseconds) })
    }
}
