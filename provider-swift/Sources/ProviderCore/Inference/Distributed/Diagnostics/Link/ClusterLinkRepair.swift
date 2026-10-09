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
    ///
    /// With `keeping`, a ready port also qualifies when its address is one
    /// Darkbloom added without the job that keeps it: the fix then only
    /// installs that job.
    static func make(for report: ClusterLinkReadinessReport, device requested: String?,
                     keeping: Bool = false) -> ClusterLinkFixPlan {
        typealias Device = ClusterLinkReadinessReport.Device
        guard !report.devices.isEmpty else { return .stop(.nothingFixable(report.state)) }
        let onlyNeedsKeeping: (Device) -> Bool = { keeping && $0.portActive && $0.verdict == .ready && $0.addressIsTemporary }
        let target: Device
        if let requested {
            guard let named = report.devices.first(where: { $0.device == requested }) else { return .stop(.deviceNotListed) }
            if named.verdict == .ready, !onlyNeedsKeeping(named) { return .stop(.alreadyReady) }
            target = named
        } else {
            let ready = report.state == .ready
            let candidates = report.devices.filter(ready ? onlyNeedsKeeping : lacksOnlyAnAddress)
            guard let only = candidates.first else { return .stop(ready ? .alreadyReady : .nothingFixable(report.state)) }
            guard candidates.count == 1 else { return .choose(among: candidates.map(\.device)) }
            target = only
        }
        // The names came from validated tool output; they are checked again
        // here because this is where a privileged command starts.
        guard lacksOnlyAnAddress(target) || onlyNeedsKeeping(target), ClusterLinkName.isDevice(target.device),
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
/// link-local address of its own and keep it there, or take all of that away
/// again. Every change is a fixed list of system commands that macOS runs only
/// after the person at the screen approves its authorization prompt.
public enum ClusterLinkRepair {
    public enum Mode: Sendable, Equatable {
        /// The address, and the launchd job that puts it back when macOS removes it.
        case durable
        /// The address alone, for as long as macOS leaves it.
        case temporary
    }

    /// Everything the flows touch outside themselves, so that checks can
    /// script a Mac without a child process, a prompt or a file.
    struct Environment {
        /// A fresh runner for one bounded round of reading state.
        var toolRunner: () -> ClusterLinkToolRunner
        var requestApproval: (ClusterLinkPrivilegedRequest) -> ClusterLinkApprovalResult
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
    /// With `dryRun` nothing is asked or changed; the result lists the
    /// commands an approval would run.
    public static func fix(device: String?, mode: Mode = .durable, dryRun: Bool = false) -> ClusterLinkRepairResult {
        guard let environment = liveEnvironment() else { return .init(operation: .fix, outcome: .recordUnavailable) }
        return fix(device: device, mode: mode, dryRun: dryRun, in: environment)
    }

    /// Blocking: waits for the person at the screen to answer the prompt,
    /// unless `dryRun`.
    public static func remove(device: String?, dryRun: Bool = false) -> ClusterLinkRepairResult {
        guard let environment = liveEnvironment() else { return .init(operation: .remove, outcome: .recordUnavailable) }
        return remove(device: device, dryRun: dryRun, in: environment)
    }

    static func fix(device requested: String?, mode: Mode, dryRun: Bool,
                    in environment: Environment) -> ClusterLinkRepairResult {
        let run = environment.toolRunner()
        let device: String, interface: String
        // The record tells an address of Darkbloom's own from any other. One
        // that cannot be read stops the fix only once there is something to do.
        let record = try? environment.loadRecord()
        let report = ClusterLinkReadinessProbe.inspect(run: run, recorded: record ?? ClusterLinkAliasRecord())
        switch ClusterLinkFixPlan.make(for: report, device: requested, keeping: mode == .durable) {
        case .stop(let outcome):
            // A stop about a named port says which port it is about.
            let named = report.devices.first { $0.device == requested }
            return .init(operation: .fix, outcome: outcome, device: named?.device, interface: named?.interface)
        case .choose(let candidates): return .init(operation: .fix, outcome: .ambiguousPorts, candidates: candidates)
        case .act(let plannedDevice, let plannedInterface): (device, interface) = (plannedDevice, plannedInterface)
        }
        func ended(_ outcome: ClusterLinkRepairOutcome, kept: Bool = false, plannedCommands: [String] = [],
                   manualCommands: [String] = []) -> ClusterLinkRepairResult {
            .init(operation: .fix, outcome: outcome, device: device, interface: interface, durable: mode == .durable || kept,
                plannedCommands: plannedCommands, manualCommands: manualCommands)
        }
        // Without a baseline there is nothing to verify the change against.
        guard let baseline = ClusterLinkTopology.observe(run: run) else { return ended(.nothingFixable(.probeFailed)) }
        guard let record else { return ended(.recordUnavailable) }
        // A port Darkbloom has addressed before gets the same address back,
        // which is the one this Mac derives. A recorded address that differs
        // came with a copied home directory or from before a hardware change:
        // it is used only while something of it is still on this Mac, so two
        // Macs with the same record do not end up with the same address.
        let derived = environment.machineIdentifier().map { ClusterLinkLocalAddress.derived(machineIdentifier: $0, interface: interface) }
        let address: ClusterLinkLocalAddress
        if let recorded = record.alias(on: interface)?.address, derived == nil || recorded == derived
            || ClusterLinkFixRemnants.observed(interface: interface, address: recorded, run: run)?.isEmpty != true {
            address = recorded
        } else {
            guard let derived else { return ended(.machineIdentityUnavailable) }
            address = derived
        }
        // The plan has already validated the interface; the request type checks
        // it once more, because nothing unvalidated may reach the prompt.
        guard let request = ClusterLinkPrivilegedRequest(mode == .durable ? .keepAddress : .addAddress,
                                                         interface: interface, address: address) else {
            return ended(.nothingFixable(.probeFailed))
        }
        if dryRun { return ended(.dryRun, plannedCommands: request.commands) }
        // Recorded before the prompt, so that nothing can exist that
        // `--remove` does not know about.
        let alias = ClusterLinkAliasRecord.Alias(interface: interface, address: address)
        let recordedBefore = record.alias(on: interface) != nil
        guard (try? environment.updateRecord { $0.set(alias) }) != nil else { return ended(.recordUnavailable) }
        func forgetNewAliasUnlessSomethingRemains() {
            // An entry from an earlier fix stays as it was. A new one goes
            // only once the port is seen with nothing of the fix on it:
            // commands that reported an error may still have run in part.
            guard !recordedBefore, ClusterLinkFixRemnants.observed(interface: interface, address: address,
                                                                   run: environment.toolRunner())?.isEmpty == true else { return }
            try? environment.updateRecord { $0.forget(interface: interface) }
        }
        switch environment.requestApproval(request) {
        case .declined:
            forgetNewAliasUnlessSomethingRemains()
            return ended(.approvalDeclined)
        case .unavailable:
            // The entry stays: what the administrator adds with the manual
            // commands is then still this record's to remove.
            return ended(.approvalUnavailable, manualCommands: request.manualCommands)
        case .commandFailed:
            forgetNewAliasUnlessSomethingRemains()
            return ended(.commandFailed)
        case .applied:
            // Recorded again: while the prompt was open, another command that
            // did not see the address yet may have cleared the entry as spent.
            try? environment.updateRecord { $0.set(alias) }
            var unmet = unmetConditions(device: device, baseline: baseline, in: environment)
            // A job from an earlier fix keeps a temporary address as well.
            let kept = ClusterLinkAddressKeeper(interface: interface, address: address)?
                .isRunning(run: environment.toolRunner()) == true
            if mode == .durable, !kept { unmet.append(.addressKeeperNotRunning) }
            return ended(unmet.isEmpty ? .fixed : .appliedButNotReady(unmet), kept: kept)
        }
    }

    static func remove(device requested: String?, dryRun: Bool, in environment: Environment) -> ClusterLinkRepairResult {
        typealias Alias = ClusterLinkAliasRecord.Alias
        guard let record = try? environment.loadRecord() else { return .init(operation: .remove, outcome: .recordUnavailable) }
        let wanted = requested.flatMap(ClusterLinkName.interface(ofDevice:))
        // A keeper whose record is gone, because the home directory was reset
        // or another account installed it, is still Darkbloom's to remove:
        // its job definition names the port and the address.
        let recorded = (record.aliases + orphanedKeepers(notIn: record, run: environment.toolRunner()))
            .filter { requested == nil || $0.interface == wanted }
        guard !recorded.isEmpty else { return .init(operation: .remove, outcome: .nothingRecorded) }
        func ended(_ outcome: ClusterLinkRepairOutcome, _ alias: Alias?, plannedCommands: [String] = [],
                   manualCommands: [String] = []) -> ClusterLinkRepairResult {
            .init(operation: .remove, outcome: outcome, device: alias.map { ClusterLinkName.device(ofInterface: $0.interface) },
                interface: alias?.interface, plannedCommands: plannedCommands, manualCommands: manualCommands)
        }
        func remnants(of alias: Alias) -> ClusterLinkFixRemnants? {
            ClusterLinkFixRemnants.observed(interface: alias.interface, address: alias.address, run: environment.toolRunner())
        }
        func forget(_ aliases: [Alias]) {
            guard !aliases.isEmpty, !dryRun else { return }
            // An update that fails leaves a stale entry, which the next removal clears the same way.
            try? environment.updateRecord { record in aliases.forEach { record.forget(interface: $0.interface) } }
        }
        let onlyRecorded = recorded.count == 1 ? recorded.first : nil
        var remaining = [(alias: Alias, remnants: ClusterLinkFixRemnants)]()
        for alias in recorded {
            guard let found = remnants(of: alias) else { return ended(.nothingFixable(.probeFailed), onlyRecorded) }
            if !found.isEmpty { remaining.append((alias, found)) }
        }
        // A temporary address goes when macOS next reconfigures the port: entries with nothing left are spent.
        forget(recorded.filter { alias in !remaining.contains { $0.alias == alias } })
        guard let target = remaining.first else { return ended(.alreadyAbsent, onlyRecorded) }
        guard remaining.count == 1 else {
            return .init(operation: .remove, outcome: .ambiguousPorts,
                candidates: remaining.map { ClusterLinkName.device(ofInterface: $0.alias.interface) })
        }
        // A decoded record holds only validated names, and the request type checks again.
        guard let request = ClusterLinkPrivilegedRequest(.remove(target.remnants), interface: target.alias.interface,
                                                         address: target.alias.address) else {
            return ended(.recordUnavailable, target.alias)
        }
        if dryRun { return ended(.dryRun, target.alias, plannedCommands: request.commands) }
        let answer = environment.requestApproval(request)
        switch answer {
        case .declined: return ended(.approvalDeclined, target.alias)
        case .unavailable: return ended(.approvalUnavailable, target.alias, manualCommands: request.manualCommands)
        case .applied, .commandFailed:
            // What is left decides, not the exit status: a command can fail
            // only because another had already done its work.
            guard remnants(of: target.alias)?.isEmpty == true else {
                return ended(answer == .applied ? .removalNotVerified : .commandFailed, target.alias)
            }
            forget([target.alias])
            return ended(.removed, target.alias)
        }
    }

    /// Keepers that are installed for ports the record does not name, as
    /// aliases a removal can act on. Only a job definition that is exactly
    /// one Darkbloom writes is taken for its own.
    private static func orphanedKeepers(notIn record: ClusterLinkAliasRecord,
                                        run: ClusterLinkToolRunner) -> [ClusterLinkAliasRecord.Alias] {
        guard case .output(let listing) = run(.keeperJobFileList) else { return [] }
        return ClusterLinkAddressKeeper.installedInterfaces(inListing: listing).filter { record.alias(on: $0) == nil }
            .compactMap { interface in
                guard case .output(let definition) = run(.keeperJobFile(interface: interface)),
                      let keeper = ClusterLinkAddressKeeper.described(byJobJSON: definition, interface: interface) else { return nil }
                return .init(interface: interface, address: keeper.address)
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
