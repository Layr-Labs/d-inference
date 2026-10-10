import Foundation

/// Link setup v2 inside `darkbloom cluster link --fix` and `--remove`: isolate
/// a cluster port under one macOS approval, and put everything back under
/// another. The first version's fix still runs where the network around the
/// port was not read and for `--temporary`.
extension ClusterLinkRepair {
    /// macOS configures the new service and the GID follows within moments.
    /// This many looks, one second apart, is the whole wait after an approval.
    static let isolationVerificationAttempts = 15

    static func isolate(device: String, interface: String, status: ClusterLinkIsolationStatus,
                        aliasRecord: ClusterLinkAliasRecord?, isolationRecord: ClusterLinkIsolationRecord?,
                        dryRun: Bool, in environment: Environment) -> ClusterLinkRepairResult {
        func ended(_ outcome: ClusterLinkRepairOutcome, plannedCommands: [String] = [],
                   manualCommands: [String] = []) -> ClusterLinkRepairResult {
            .init(operation: .fix, outcome: outcome, device: device, interface: interface, durable: true, isolated: true,
                plannedCommands: plannedCommands, manualCommands: manualCommands, hardwarePort: status.hardwarePort,
                bridge: status.bridge)
        }
        // What the approval cannot cure stops everything before a prompt.
        let blockers = status.blockers
        guard blockers.isEmpty else { return ended(.isolationRefused(blockers)) }
        guard let isolationRecord, let aliasRecord else { return ended(.recordUnavailable) }
        // A port isolated before keeps its address; otherwise this Mac's own.
        let address: ClusterLinkClusterAddress
        if let recorded = isolationRecord.entry(on: interface)?.address {
            address = recorded
        } else {
            guard let machine = environment.machineIdentifier() else { return ended(.machineIdentityUnavailable) }
            address = .derived(machineIdentifier: machine, interface: interface)
        }
        // What the first version left on the port goes with the same approval.
        let run = environment.toolRunner()
        let oldAlias = aliasRecord.alias(on: interface)
        let oldAddressCarried = oldAlias.flatMap {
            ClusterLinkFixRemnants.observed(interface: interface, address: $0.address, run: run)?.address
        } == true
        guard let hardwarePort = status.hardwarePort,
              let plan = ClusterLinkIsolationPlan(interface: interface, address: address, hardwarePort: hardwarePort,
                  bridge: status.preferenceBridge.map { .init(bridge: $0.bridge, index: $0.index) },
                  servicesToDisable: status.otherServices, replaceClusterService: status.clusterServicePresent,
                  linkLocalToRemove: oldAddressCarried ? oldAlias?.address : nil,
                  keeperToRemove: keeperInstalled(interface: interface, run: run)),
              let request = ClusterLinkIsolationRequest(.isolate(plan)) else {
            return ended(.isolationRefused([.serviceNameUnsafe]))
        }
        if dryRun { return ended(.dryRun, plannedCommands: request.commands) }

        // Recorded before the prompt, so a removal knows everything that may change.
        let entry = ClusterLinkIsolationRecord.Entry(interface: interface, address: address, hardwarePort: hardwarePort,
            bridge: plan.bridge, disabledServices: plan.servicesToDisable)
        let recordedBefore = isolationRecord.entry(on: interface) != nil
        guard (try? environment.updateIsolationRecord { $0.set(entry) }) != nil else { return ended(.recordUnavailable) }
        func forgetUnlessSomethingChanged() {
            // An entry from an earlier attempt stays. A new one goes only once
            // the port is seen exactly as before: a failed command may have
            // run after others did their work.
            // A keeper of the first version was there before and does not count.
            guard !recordedBefore, let restore = restoreNeeded(interface: interface, entry: entry,
                      run: environment.toolRunner(), countingKeeper: false), restore.isEmpty else { return }
            try? environment.updateIsolationRecord { $0.forget(interface: interface) }
        }
        switch environment.requestIsolationApproval(request) {
        case .declined:
            forgetUnlessSomethingChanged()
            return ended(.approvalDeclined)
        case .unavailable:
            // The entry stays: what an administrator changes with the manual
            // commands is then still this record's to restore.
            return ended(.approvalUnavailable, manualCommands: request.manualCommands)
        case .commandFailed:
            forgetUnlessSomethingChanged()
            return ended(.commandFailed)
        case .applied:
            break
        }
        // The first version's entry is spent once nothing of it is left.
        if let oldAlias, ClusterLinkFixRemnants.observed(interface: interface, address: oldAlias.address,
                                                         run: environment.toolRunner())?.isEmpty == true {
            try? environment.updateRecord { $0.forget(interface: interface) }
        }
        var final: ClusterLinkReadinessReport.Device?
        let recorded = (try? environment.loadIsolationRecord()) ?? ClusterLinkIsolationRecord()
        for attempt in 1...isolationVerificationAttempts {
            let report = ClusterLinkReadinessProbe.inspect(run: environment.toolRunner(), readingIsolation: true,
                isolationRecord: recorded)
            final = report.devices.first { $0.device == device }
            if (final?.verdict == .ready && final?.isolation?.isolated == true) || attempt == isolationVerificationAttempts { break }
            environment.pause()
        }
        guard let final, let isolation = final.isolation else { return ended(.appliedButNotReady([.stateUnreadable])) }
        guard isolation.isolated else { return ended(.appliedButNotIsolated(isolation.findings)) }
        guard final.verdict == .ready else { return ended(.appliedButNotReady([.deviceNotReady])) }
        return ended(.fixed)
    }

    /// `--remove` for what link setup v2 changed. Nil when it changed nothing
    /// that is on record or recognisable on this Mac, so the first version's
    /// removal runs instead.
    static func removeIsolation(device requested: String?, dryRun: Bool,
                                in environment: Environment) -> ClusterLinkRepairResult? {
        guard let record = try? environment.loadIsolationRecord() else {
            return .init(operation: .remove, outcome: .recordUnavailable, isolated: true)
        }
        let run = environment.toolRunner()
        let machine = ClusterLinkIsolationInspection.machine(run: run)
        let wanted = requested.flatMap(ClusterLinkName.interface(ofDevice:))
        // A service of Darkbloom's whose record is gone is still Darkbloom's
        // to remove: its name says which port it is for.
        let orphans = (machine?.services ?? []).compactMap { service -> String? in
            guard let interface = ClusterLinkServiceName.clusterInterface(ofService: service.name),
                  service.interface == interface, record.entry(on: interface) == nil else { return nil }
            return interface
        }
        let candidates = (record.entries.map(\.interface) + orphans).filter { wanted == nil || $0 == wanted }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1, let interface = candidates.first else {
            return .init(operation: .remove, outcome: .ambiguousPorts,
                candidates: candidates.map(ClusterLinkName.device(ofInterface:)), isolated: true)
        }
        let entry = record.entry(on: interface)
        let rdmaDevice = ClusterLinkName.device(ofInterface: interface)
        func ended(_ outcome: ClusterLinkRepairOutcome, plannedCommands: [String] = [],
                   manualCommands: [String] = []) -> ClusterLinkRepairResult {
            .init(operation: .remove, outcome: outcome, device: rdmaDevice, interface: interface, isolated: true,
                plannedCommands: plannedCommands, manualCommands: manualCommands, hardwarePort: entry?.hardwarePort,
                bridge: entry?.bridge?.bridge)
        }
        func forget() {
            guard !dryRun else { return }
            try? environment.updateIsolationRecord { $0.forget(interface: interface) }
        }
        guard let restore = restoreNeeded(interface: interface, entry: entry, run: run) else {
            return ended(.nothingFixable(.probeFailed))
        }
        guard let request = ClusterLinkIsolationRequest(.restore(restore)) else {
            forget()
            return ended(.alreadyAbsent)
        }
        if dryRun { return ended(.dryRun, plannedCommands: request.commands) }
        let answer = environment.requestIsolationApproval(request)
        switch answer {
        case .declined: return ended(.approvalDeclined)
        case .unavailable: return ended(.approvalUnavailable, manualCommands: request.manualCommands)
        case .applied, .commandFailed:
            // What is left decides, not the exit status.
            guard restoreNeeded(interface: interface, entry: entry, run: environment.toolRunner())?.isEmpty == true else {
                return ended(answer == .applied ? .removalNotVerified : .commandFailed)
            }
            forget()
            return ended(.removed)
        }
    }

    /// What is still to undo for a port: read now, from the record entry when
    /// there is one. Nil when a reading failed.
    static func restoreNeeded(interface: String, entry: ClusterLinkIsolationRecord.Entry?,
                              run: ClusterLinkToolRunner, countingKeeper: Bool = true) -> ClusterLinkIsolationRestore? {
        guard let machine = ClusterLinkIsolationInspection.machine(run: run),
              case .output(let listing) = run(.interfaceList) else { return nil }
        let ours = ClusterLinkServiceName.cluster(interface: interface)
        let clusterServicePresent = machine.services.contains { $0.name == ours }
        let toEnable = (entry?.disabledServices ?? []).filter { name in
            machine.services.contains { $0.name == name && !$0.enabled }
        }
        var bridge: ClusterLinkIsolationPlan.BridgeSlot?
        if let slot = entry?.bridge, let members = machine.preferenceBridges[slot.bridge], !members.contains(interface) {
            bridge = .init(bridge: slot.bridge, index: min(slot.index, members.count))
        }
        // While the service exists macOS removes its address with it; one
        // left behind without a service is taken off by hand.
        let leftover = entry.flatMap { entry in
            !clusterServicePresent && ClusterLinkNetworkFacts.lists(entry.address.dottedDecimal, on: interface, inListing: listing)
                ? entry.address : nil
        }
        return ClusterLinkIsolationRestore(interface: interface, removeClusterService: clusterServicePresent,
            servicesToEnable: toEnable, bridge: bridge, addressToRemove: leftover,
            keeperToRemove: countingKeeper && keeperInstalled(interface: interface, run: run))
    }

    /// Whether the first version's keeper is loaded or its file exists.
    private static func keeperInstalled(interface: String, run: ClusterLinkToolRunner) -> Bool {
        if case .output = run(.keeperJob(interface: interface)) { return true }
        guard case .output(let listing) = run(.keeperJobFileList) else { return false }
        return ClusterLinkAddressKeeper.installedInterfaces(inListing: listing).contains(interface)
    }
}
