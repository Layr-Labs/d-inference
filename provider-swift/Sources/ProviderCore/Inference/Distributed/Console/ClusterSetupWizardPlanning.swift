import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Step 4's decision for every model folder, from readings already taken:
/// both Macs' profiles, each model's layout and capability record, and the
/// pair description the wizard plans from. Pure, so a check can run it whole.
enum ClusterSetupPlanning {
    /// What the live step read for one model folder on this Mac.
    struct ModelReading: Sendable {
        let model: ClusterSetupLocalModel
        /// The plan tool's layout, or why it could not give one.
        let layout: Result<ClusterModelLayout, ClusterSetupFailure>
        /// The worker's capability record for this model, its exact bytes and their digest.
        let capability: Result<(record: ClusterRuntimeCapability, data: Data, sha256: String), ClusterSetupFailure>
        /// The tokenizer and chat template files the manifest pins.
        let tokenizerFiles: [ClusterConfiguration.TokenizerFile]
        /// A requested assistant has either its complete singleton quote or a
        /// refusal. On a local cluster a refusal stands; through Darkbloom, where
        /// the pair served plain tensor parallel before the assistant was
        /// declared, a refused assistant gives way to `targetFallbackQuote` and
        /// the plan says why (`assistantRefusedLine`).
        var tensorAssistantQuote: Result<ClusterPlacementTensorBatchQuote, ClusterSetupFailure>? = nil
        /// Automatic discovery's ordinary request-owned quote, kept only beside a
        /// discovered (not explicitly requested) assistant: used when no placement
        /// can hold that assistant's complete reservation now.
        var targetFallbackQuote: Result<ClusterPlacementTensorBatchQuote, ClusterSetupFailure>? = nil
        /// The same owners' first widening (two lanes) quotes; they only steer
        /// the retained split. Absent, the split is chosen by speed alone.
        var tensorWideningQuote: ClusterPlacementTensorBatchQuote? = nil
        var targetFallbackWideningQuote: ClusterPlacementTensorBatchQuote? = nil
        /// The same owners' complete quotes at the wider widths: the setup
        /// saves the widest both Macs admit now (`ClusterPlacementTensorWidth`).
        var tensorWidthQuotes: [ClusterPlacementTensorBatchQuote] = []
        var targetFallbackWidthQuotes: [ClusterPlacementTensorBatchQuote] = []
    }

    typealias PlacementDecision = (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?)

    /// The line a plan carries when the discovered assistant gave way to the ordinary target.
    static let assistantDoesNotFit = "The embedded assistant's complete reservation does not fit both Macs' memory now; "
        + "this plan serves without speculative decoding."

    /// The line a plan through Darkbloom carries when the declared assistant's quote was refused and the plan serves
    /// the ordinary target instead: the refusal, bounded, in the one line the screen shows under the model.
    static func assistantRefusedLine(_ failure: ClusterSetupFailure) -> String {
        "Qwen's speculative assistant could not be planned (" + ClusterConsoleText.bounded(failure.text, maximum: 160)
            + "); this plan serves without speculative decoding."
    }

    /// The discovered assistant's plan, or, when no placement can hold it, the
    /// ordinary request-owned target's plan. Without a fallback (an explicitly
    /// requested assistant) the assistant's decision stands, refusal included.
    static func assistantOrTarget(_ quote: ClusterPlacementTensorBatchQuote?, fallback: ClusterPlacementTensorBatchQuote?,
                                  _ decide: (ClusterPlacementTensorBatchQuote?) throws -> PlacementDecision) throws
        -> (decision: PlacementDecision, quote: ClusterPlacementTensorBatchQuote?) {
        let first = try decide(quote)
        guard first.result.chosen == nil, quote?.assistant != nil, let fallback, fallback.assistant == nil else {
            return (first, quote)
        }
        let target = try decide(fallback)
        guard target.result.chosen != nil else { return (first, quote) }
        return ((lines: [assistantDoesNotFit] + target.lines, result: target.result, setup: target.setup), fallback)
    }

    /// One model's option, and the setups adopting it would write.
    struct Decision: Sendable {
        let option: ClusterSetupModelOption
        let setup: ClusterPlacementSetup?
        let capability: (data: Data, sha256: String)?
        /// The setup of each plan in `option.familyPlans`, by its plan key (`ClusterSetupState.planKey`).
        var familySetups: [String: ClusterPlacementSetup] = [:]

        /// The listed plan, or one of `option.familyPlans`, whose key is `planKey`, with its setup.
        func placement(planKey: String) -> (plan: ClusterSetupPlanSummary, setup: ClusterPlacementSetup)? {
            if let plan = option.plan, let setup, ClusterSetupState.planKey(option.model, plan) == planKey { return (plan, setup) }
            guard let setup = familySetups[planKey],
                  let plan = option.familyPlans?.first(where: { ClusterSetupState.planKey(option.model, $0) == planKey }) else { return nil }
            return (plan, setup)
        }
    }

    /// What loads when a mode is chosen: each Mac's share, and the requests the pair then serves at once.
    struct Loads: Sendable, Equatable {
        var shares: [ClusterSetupPlanSummary.Mode.Share]
        var concurrentRequests: Int?
    }

    /// The modes the question offers, each with what loads when it is chosen: the listed plan's split for the listed
    /// plan's own family (`listedMode`), another family's own plan (`families`) for that family. A family with no plan
    /// of its own (it could not be planned in that mode) shows no split.
    static func offered(_ modes: [ClusterSetupPlanSummary.Mode], listed: Loads, listedMode: ClusterGenerationMode,
                        families: [ClusterForcedMode: Loads]) -> [ClusterSetupPlanSummary.Mode] {
        modes.map { mode in
            guard let raw = ClusterGenerationMode(rawValue: mode.mode),
                  let family = ClusterForcedMode.allCases.first(where: { $0.admits(raw) }) else { return mode }
            let loads = family.admits(listedMode) ? listed : families[family] ?? Loads(shares: [], concurrentRequests: nil)
            var offered = mode
            offered.shares = loads.shares
            offered.concurrentRequests = loads.concurrentRequests
            return offered
        }
    }

    /// What `placement` loads: each rank's share, named for the Mac that runs it, and the requests its setup serves at
    /// once (`DistributedInstalledPlan.batchLanes`, without the diagnostic switch); nil when the setup can't be read.
    static func loads(_ placement: ClusterPlacementCandidate, setup: ClusterPlacementSetup?, localMemberID: String,
                      capability: (record: ClusterRuntimeCapability, data: Data, sha256: String)) -> Loads {
        let shares = placement.ranks.enumerated().map { index, rank in
            ClusterSetupPlanSummary.Mode.Share(local: rank.device == localMemberID, firstLayer: rank.firstLayer, endLayer: rank.endLayer,
                share: placement.mode.usesTensorParallelPrefill ? (placement.shares?[index] ?? 1 / Double(placement.ranks.count)) : nil)
        }
        let configuration = setup?.configurations[localMemberID].flatMap {
            try? ClusterConfigurationCodec.decode($0, capability: capability.record, capabilitySHA256: capability.sha256)
        }
        return .init(shares: shares, concurrentRequests: configuration.map {
            DistributedInstalledPlan.batchLanes(configuration: $0, capability: capability.record, environment: [:]) ?? 1
        })
    }

    /// The pair description for another model folder: the same members,
    /// installations and trust; that folder's directory, identity and files.
    /// A Mac that holds the same entry under another folder name (a catalog
    /// download beside a copy) is given its own folder (`folders`).
    static func pairDescription(_ base: ClusterPairDescription, folder: String, folders: [String: String] = [:],
                            publicModelID: String, capabilitySHA256: String,
                            tokenizerFiles: [ClusterConfiguration.TokenizerFile]) -> ClusterPairDescription {
        ClusterPairDescription(schema: base.schema, clusterID: base.clusterID, publicModelID: publicModelID,
            capabilitySHA256: capabilitySHA256, chunkTokens: base.chunkTokens, requestTimeoutSeconds: base.requestTimeoutSeconds,
            coordinatorPort: base.coordinatorPort,
            members: base.members.map { member in
                let directory = URL(fileURLWithPath: member.modelDirectory).deletingLastPathComponent().appendingPathComponent(folders[member.id] ?? folder).path
                return .init(id: member.id, host: member.host, port: member.port, user: member.user, ownerExecutable: member.ownerExecutable,
                    workerExecutable: member.workerExecutable, modelDirectory: directory, runtimeBinarySHA256: member.runtimeBinarySHA256,
                    jacclDevice: member.jacclDevice, linkAddress: member.linkAddress, trust: member.trust,
                    linkSecretFile: member.linkSecretFile)
            },
            tokenizerFiles: tokenizerFiles, linkControl: base.linkControl)
    }

    /// The manifest's tokenizer and chat template entries, as a setup pins them.
    static func tokenizerFiles(manifest data: Data) -> [ClusterConfiguration.TokenizerFile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { file in
            guard let path = file["path"] as? String, let digest = file["sha256"] as? String, let role = file["role"] as? String,
                  role == "tokenizer" || role == "template" else { return nil }
            return .init(path: path, sha256: digest, purpose: role == "template" ? .chatTemplate : .tokenizer)
        }
    }

    /// Plans every model folder this Mac has. The local member leads every
    /// plan: the installed session is started from rank 0, over the pinned
    /// route only this Mac holds. `coordinator`: the setup will serve through
    /// the coordinator, so tensor parallel is planned with equal shares only
    /// (`ClusterPlacementFlow.decide`).
    static func decide(readings: [ModelReading], description: ClusterPairDescription, localMemberID: String,
                       localProfile: ClusterDeviceProfile, peerProfile: ClusterDeviceProfile, peerModels: [ClusterSetupLocalModel],
                       measurements: [ClusterSpeedMeasurement], leader: String?? = .none,
                       served: [ClusterServedSpeedRecords.Entry] = [], link: ClusterLinkCosts = .unmeasured,
                       shareProbes: ClusterShareProbeHistory? = nil, now: Double = Date().timeIntervalSince1970,
                       peerMayReceive: Bool = false, keeping: [String: ClusterGenerationMode] = [:],
                       coordinator: Bool = false, chosenModes: [String: ClusterForcedMode] = [:]) -> [Decision] {
        // The wizard's own steps lead from this Mac; the onboarding and the service's re-plans pass the Mac the cluster
        // was set up on (`ClusterControlDerivation.planLeader`). A `nil` leader leaves rank 0 to the planner.
        let sessionLeader: String? = leader ?? localMemberID
        let peerID = description.members.first { $0.id != localMemberID }?.id ?? "the other Mac"
        // Developer bench only (`ClusterBenchChip`): both Macs are planned and checked as that chip; a release build
        // refuses to plan while it is set (`ClusterPlacementFlow.decide`).
        let benchChip = (try? ClusterBenchChip.planningChipName(environment: ProcessInfo.processInfo.environment)) ?? nil
        return readings.map { reading in
            let onOther = peerModels.contains { $0.sameEntry(reading.model) }
            func blocked(_ reason: String) -> Decision {
                .init(option: .init(model: reading.model, onOtherMac: onOther, blocker: reason, plan: nil), setup: nil, capability: nil)
            }
            // The onboarding copies a model the other Mac lacks over the cable (or it is downloaded) before the setup is synced.
            guard onOther || peerMayReceive else { return blocked("Not on the other Mac: copy it there first.") }
            let layout: ClusterModelLayout
            switch reading.layout {
            case .success(let value): layout = value
            // The reading's own error stays out of the screen's line: it names internal checks, not anything to do.
            case .failure: return blocked(notClusterModel)
            }
            let capability: (record: ClusterRuntimeCapability, data: Data, sha256: String)
            switch reading.capability {
            case .success(let value): capability = value
            case .failure: return blocked(notClusterModel)
            }
            guard !reading.tokenizerFiles.isEmpty else { return blocked("its manifest names no tokenizer file") }
            let peerFolder = peerModels.first { $0.sameEntry(reading.model) }?.folder
            let pair = pairDescription(description, folder: reading.model.folder,
                folders: peerFolder.map { [peerID: $0] } ?? [:], publicModelID: reading.model.modelID,
                capabilitySHA256: capability.sha256, tokenizerFiles: reading.tokenizerFiles)
            // The owner's flow (2026-10-14 08:45): a model is refused only when no cluster stage adapter runs it, or
            // (below) when no sharded layout fits both Macs' memory. Records never refuse it; they steer the planner
            // away from the shapes that diverged and decide public traffic, which the plan states in one line.
            if pairServingRefused(capability.record, publicModelID: reading.model.modelID) {
                return blocked(noStageAdapter)
            }
            do {
                // After a Darkbloom update the same model keeps the mode the pair served it in (`keeping`, by model id),
                // unless the planner and the pair's own served requests both find another faster (`ClusterServedModes`).
                let incumbent = keeping[reading.model.modelID]
                // Each Mac's share probes of this model, by member ID (`ClusterShareProbeHistory`).
                let probes = shareProbes?.shareRates(artifactSHA256: capability.record.artifactSHA256,
                    members: description.members.map(\.id), now: now) ?? [:]
                // Through Darkbloom a refused assistant leaves the pair its ordinary target (`ModelReading.tensorAssistantQuote`).
                var refusedAssistant: ClusterSetupFailure?
                if coordinator, case .failure(let failure)? = reading.tensorAssistantQuote, case .success? = reading.targetFallbackQuote {
                    refusedAssistant = failure
                }
                let discovered = try refusedAssistant == nil ? reading.tensorAssistantQuote?.get() : reading.targetFallbackQuote?.get()
                func widening(_ quote: ClusterPlacementTensorBatchQuote?) -> ClusterPlacementTensorBatchQuote? {
                    quote == nil ? nil : quote == discovered && refusedAssistant == nil ? reading.tensorWideningQuote : reading.targetFallbackWideningQuote
                }
                func widths(_ quote: ClusterPlacementTensorBatchQuote?) -> [ClusterPlacementTensorBatchQuote] {
                    quote == nil ? [] : quote == discovered && refusedAssistant == nil ? reading.tensorWidthQuotes : reading.targetFallbackWidthQuotes
                }
                // The plan a start makes for `family` (nil: the planner's own choice), with the quote it was made with.
                func place(_ family: ClusterForcedMode?, raised: (local: ClusterDeviceProfile, peer: ClusterDeviceProfile)? = nil) throws
                    -> (decided: (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?),
                        quote: ClusterPlacementTensorBatchQuote?) {
                    let localProfile = raised?.local ?? localProfile, peerProfile = raised?.peer ?? peerProfile
                    let selected = try assistantOrTarget(discovered,
                        fallback: try? reading.targetFallbackQuote?.get()) { quote in
                        try ClusterPlacementFlow.decide(description: pair, capability: capability.record, localMemberID: localMemberID,
                            localProfile: localProfile, peerProfile: peerProfile, layout: layout, measurements: measurements,
                            tensorAssistantQuote: quote, tensorWideningQuote: widening(quote), tensorWidthQuotes: widths(quote),
                            leader: sessionLeader, served: served, link: link, shareProbes: probes, incumbentMode: incumbent,
                            chosenMode: family, coordinator: coordinator)
                    }
                    var decided = selected.decision
                    let assistantQuote = selected.quote, fellBack = discovered != nil && selected.quote != discovered
                    // Ports chosen on this Mac hold only when it leads; a plan the other Mac leads names the conventional ones.
                    if let setup = decided.setup, setup.leaderID != localMemberID, pair.ports != ClusterSetupPorts.Choice.conventional {
                        decided = try ClusterPlacementFlow.decide(description: pair.withPorts(.conventional), capability: capability.record,
                            localMemberID: localMemberID, localProfile: localProfile, peerProfile: peerProfile, layout: layout,
                            measurements: measurements, tensorAssistantQuote: assistantQuote,
                            tensorWideningQuote: widening(assistantQuote), tensorWidthQuotes: widths(assistantQuote),
                            leader: sessionLeader, served: served, link: link, shareProbes: probes, incumbentMode: incumbent,
                            chosenMode: family, coordinator: coordinator)
                        if fellBack { decided.lines = [assistantDoesNotFit] + decided.lines }
                    }
                    return (decided, assistantQuote)
                }
                let placed = try place(chosenModes[reading.model.modelID])
                let decided = placed.decided, assistantQuote = placed.quote
                guard let chosen = decided.result.chosen else {
                    // Macs by chip and memory, as pairing shows them, never by member ID.
                    let names = [localMemberID: "\(localProfile.chip), \(localProfile.physicalMemoryBytes >> 30) GB",
                                 peerID: "\(peerProfile.chip), \(peerProfile.physicalMemoryBytes >> 30) GB"]
                    // Nothing fits as the Macs are. Where `darkbloom cluster gpu-limit` runs (`ClusterGPUMemoryLimit.raisedByDarkbloom`)
                    // and a placement fits once it has, the row names that step on each Mac that needs it; nothing loads before.
                    let raisedLocal = try localProfile.withGPUMemoryLimitRaised(), raisedPeer = try peerProfile.withGPUMemoryLimitRaised()
                    if raisedLocal != nil || raisedPeer != nil,
                       let after = try? place(chosenModes[reading.model.modelID],
                                              raised: (raisedLocal ?? localProfile, raisedPeer ?? peerProfile)).decided.result.chosen,
                       after.possible,
                       let steps = gpuLimitSteps(after, profiles: [localMemberID: localProfile, peerID: peerProfile], names: names) {
                        return blocked(steps)
                    }
                    return blocked(refusalWords(decided.result, localMemberID: localMemberID, names: names,
                                                profiles: [localMemberID: localProfile, peerID: peerProfile]))
                }
                // Offered only when each Mac's start would serve the chosen placement (the planner already keeps away
                // from the shapes that diverged on these chips, so this holds unless the two disagree).
                let chips = [localMemberID: benchChip ?? localProfile.chip, peerID: benchChip ?? peerProfile.chip]
                func startRefusal(_ placement: ClusterPlacementCandidate) -> ClusterPairServingRefusal? {
                    ClusterPairServingGrants.startRefusal(
                        placement.ranks.map { chips[$0.device].flatMap { ClusterChipClass(chipName: $0) } },
                        cuts: placement.cuts, mode: placement.mode, runtimeModelID: capability.record.runtimeModelID,
                        publicModelID: reading.model.modelID, artifactSHA256: capability.record.artifactSHA256)
                }
                if let refusal = startRefusal(chosen) {
                    return blocked("not served on this pair by this build: "
                        + ClusterConsoleText.bounded(refusal.description, maximum: 200))
                }
                let profiles = [localMemberID: localProfile, peerID: peerProfile]
                // Why the plan serves without speculative decoding where the assistant gave way, in one line.
                let speculationNote = refusedAssistant.map(assistantRefusedLine)
                    ?? (discovered?.assistant != nil && assistantQuote != discovered ? assistantDoesNotFit : nil)
                var plan = summary(decided.result, chosen: chosen, lines: (refusedAssistant.map { [assistantRefusedLine($0)] } ?? [])
                    + decided.lines, localMemberID: localMemberID, profiles: profiles)
                plan.speculationNote = speculationNote
                plan.modes = modes(decided.result, served: served, pair: pair, localMemberID: localMemberID,
                                   serving: coordinator ? .darkbloom : .local, tensorAssistant: assistantQuote?.assistant != nil)
                plan.publicTraffic = ClusterPairServingGrants.publicTrafficLine(runtimeModelID: capability.record.runtimeModelID,
                    artifactSHA256: capability.record.artifactSHA256, mode: chosen.mode,
                    tensorAssistant: assistantQuote?.assistant != nil && chosen.mode == .tensorParallel)
                // Each other way the question offers is planned now as the start plans it once chosen (`chosenModes`),
                // from the same samples, and that plan is the one the start adopts: the split and the requests at once
                // the question shows are the ones that load (R4-13: GLM's pipeline was offered 1 / 44 from this plan's
                // assessment, and the start's own plan in that mode, with this Mac's speed measured again, loaded 44 / 1).
                var families: [(family: ClusterForcedMode, plan: ClusterSetupPlanSummary, setup: ClusterPlacementSetup, loads: Loads)] = []
                if let listed = plan.modes, listed.count > 1, chosenModes[reading.model.modelID] == nil {
                    for mode in listed {
                        guard let raw = ClusterGenerationMode(rawValue: mode.mode),
                              let family = ClusterForcedMode.allCases.first(where: { $0.admits(raw) }), !family.admits(chosen.mode),
                              let other = try? place(family), let placement = other.decided.result.chosen, family.admits(placement.mode),
                              startRefusal(placement) == nil, let setup = other.decided.setup else { continue }
                        families.append((family, summary(other.decided.result, chosen: placement, lines: other.decided.lines,
                            localMemberID: localMemberID, profiles: profiles), setup,
                            loads(placement, setup: setup, localMemberID: localMemberID, capability: capability)))
                    }
                    plan.modes = offered(listed, listed: loads(chosen, setup: decided.setup, localMemberID: localMemberID, capability: capability),
                        listedMode: chosen.mode, families: Dictionary(families.map { ($0.family, $0.loads) }, uniquingKeysWith: { first, _ in first }))
                    // Whether Darkbloom serves each mode publicly: the mode question's recommendation weighs it.
                    plan.modes = plan.modes?.map { mode in
                        var mode = mode
                        mode.publicTraffic = ClusterGenerationMode(rawValue: mode.mode).map {
                            ClusterPairServingGrants.publicTrafficLine(runtimeModelID: capability.record.runtimeModelID,
                                artifactSHA256: capability.record.artifactSHA256, mode: $0).hasPrefix("qualified")
                        }
                        return mode
                    }
                }
                var option = ClusterSetupModelOption(model: reading.model, onOtherMac: onOther, blocker: nil, plan: plan)
                option.familyPlans = families.isEmpty ? nil : families.map { $0.plan }
                return .init(option: option, setup: decided.setup, capability: (capability.data, capability.sha256),
                    familySetups: Dictionary(families.map { (ClusterSetupState.planKey(reading.model, $0.plan), $0.setup) },
                                             uniquingKeysWith: { first, _ in first }))
            } catch is ClusterPairServingRefusal {
                // No stage adapter of this build runs the model.
                return blocked(noStageAdapter)
            } catch where String(describing: error).contains(ClusterConfiguration.peerBuildDiffers) {
                return blocked(differentBuilds)
            } catch {
                return blocked(planFailed(error))
            }
        }
    }

    /// The plain blocker for a model whose plan threw, with the planner's own cause: "not offered on these two Macs:
    /// the plan for it failed (<cause>)" on the setup's list.
    static func planFailed(_ error: Error) -> String {
        "the plan for it failed (\(ClusterConsoleText.bounded(String(describing: error), maximum: 160)))"
    }

    /// The plain blocker for a model no cluster stage adapter of this build runs.
    static let noStageAdapter = "This build has no cluster stage adapter for this model."
    /// The plain blocker for a model folder the cluster cannot read or run (not a model, or a version of it the cluster
    /// runtime does not take).
    static let notClusterModel = "not supported on a cluster yet"
    /// The onboarding's words for such a folder when its artifact is one this build serves on a cluster: the model is
    /// supported, this copy of it is not taken (the catalog's encoding of a manifest the worker pins in another, say).
    static let copyNotTaken = "supported on a cluster, but this Mac's cluster worker does not take this copy of it"
    /// The plain blocker when the two Macs' installed cluster workers differ: nothing can be planned on both until they match.
    static let differentBuilds = ClusterOnboardingLeaderStep.differentBuildsReason
    /// The plain blocker when every placement these Macs can hold is a shape that diverged on these chips.
    static let everyShapeDiverged = "Every way these Macs can hold it diverged from its single-Mac reference on these chips."

    /// The owner's serving of the model is refused for this build: no cluster stage adapter runs it (independent of
    /// the Macs' chips and of its records). Time budgets are derived from the setup, never a per-model row.
    static func pairServingRefused(_ capability: ClusterRuntimeCapability, publicModelID: String) -> Bool {
        (try? ClusterPairServingGrants.ownerServing(runtimeModelID: capability.runtimeModelID, publicModelID: publicModelID,
                                                    artifactSHA256: capability.artifactSHA256)) == nil
    }

    /// Why a model is not offered, plain action or fact first (the screen cuts long reasons).
    /// The step a placement that fits only once some Macs' GPU limits are raised needs first: on each such Mac, its
    /// part's GPU need against the limit macOS keeps now and the limit `darkbloom cluster gpu-limit` sets, in whole GB
    /// as Macs' memory is named (the need rounded up, the limits down). Nil when no rank needs more than its Mac's limit.
    static func gpuLimitSteps(_ placement: ClusterPlacementCandidate, profiles: [String: ClusterDeviceProfile],
                              names: [String: String]) -> String? {
        let macs = placement.ranks.compactMap { rank -> String? in
            guard let profile = profiles[rank.device], let need = rank.gpuResidentBytes, need > profile.residentCapacityBytes else { return nil }
            return "on \(names[rank.device] ?? rank.device) its part needs \((need + (1 << 30) - 1) >> 30) GB of GPU memory, and macOS "
                + "allows \(profile.residentCapacityBytes >> 30) GB; `darkbloom cluster gpu-limit` raises it to "
                + "\(profile.gpuMemoryLimitCeilingBytes >> 30) GB"
        }
        guard !macs.isEmpty else { return nil }
        return "Needs `darkbloom cluster gpu-limit` first: " + macs.joined(separator: "; ") + ". Run it on "
            + (macs.count == 1 ? "that Mac" : "each of those Macs") + " (it asks once, then macOS asks an administrator), "
            + "then `darkbloom cluster` again."
    }

    static func refusalWords(_ result: ClusterPlacementResult, localMemberID: String, names: [String: String] = [:],
                             profiles: [String: ClusterDeviceProfile] = [:]) -> String {
        func name(_ device: String) -> String { names[device] ?? device }
        // Only tensor parallel fits, and it would drop a feature of the model's other modes (`ClusterModeParity`).
        if result.tensorParallel?.verdict == .dropsFeatures, let why = result.modesReason { return why }
        if let excluded = result.unqualifiedPossible, excluded > 0 {
            let alone = result.alone.first(where: { $0.fit.possible })
                .map { " \(name($0.device)) can serve it alone in single-Mac Darkbloom." } ?? ""
            return everyShapeDiverged + alone
        }
        if let alone = result.alone.first(where: { $0.fit.possible }) {
            return "\(name(alone.device)) can serve it alone in single-Mac Darkbloom."
        }
        // A GPU limit no step of Darkbloom's raises (`ClusterGPUMemoryLimit.raisedByDarkbloom`) is all that stops the
        // closest placement (each Mac's memory at rest holds its part): said as that, never as free memory.
        let closest = result.refusal?.closest?.ranks ?? []
        let memoryHolds = closest.allSatisfy { rank in profiles[rank.device].map { rank.needBytes <= $0.atRestAdmissibleBytes } ?? false }
        let gpuShort = !memoryHolds ? [] : closest.filter { rank in
            guard let profile = profiles[rank.device] else { return false }
            return !rank.withinGPUWorkingSet || (rank.gpuResidentBytes ?? 0) > profile.residentCapacityBytes
        }
        if !gpuShort.isEmpty {
            let limits = gpuShort.compactMap { rank in profiles[rank.device].map { "\(name(rank.device)) allows \($0.residentCapacityBytes >> 30) GB" } }
            return "Needs more memory: no split of it fits these Macs' GPU memory limits, even with `darkbloom cluster gpu-limit` "
                + "where it runs (" + limits.joined(separator: "; ") + "). Darkbloom raises that limit only on "
                + GLM5NextGPULimitEligibility.macs + "."
        }
        if let refusal = result.refusal {
            let total = ClusterSetupScreen.gib(refusal.modelLoadedBytes)
            return "Needs more memory: these Macs together cannot hold its \(total), even with every application closed."
        }
        return "Needs more memory: too large for these Macs together right now."
    }

    /// The mode families the screen may offer (owner, 2026-11-04: tensor parallel and pipeline both offered), the
    /// chosen first: the planner's own sharded candidates that run here (not ones that do not fit, no runtime executes,
    /// a qualification check kept out, or that would drop a feature), one per family (the pipeline family's best:
    /// plain, compact or speculative), each with the decode rate this pair served it at, read as the planner reads its
    /// served requests (`ClusterServedModes.figures` over this build's records of this model on these Macs, served the way
    /// the plan will serve: `serving`, and tensor parallel with Qwen's tensor assistant exactly when `tensorAssistant`),
    /// and the rate an earlier build last served it at (`earlierFigures`).
    static func modes(_ result: ClusterPlacementResult, served: [ClusterServedSpeedRecords.Entry], pair: ClusterPairDescription,
                      localMemberID: String, serving: ClusterServedScope, tensorAssistant: Bool) -> [ClusterSetupPlanSummary.Mode]? {
        guard let shards = result.shards else { return nil }
        let runs: Set<ClusterShardOption.Verdict> = [.chosen, .slower, .predictedFasterOnPriorOnly, .reductionNotMeasured]
        let members = Set(pair.members.map(\.id))
        let pairServed = served.filter { $0.setup.modelID == pair.publicModelID && ($0.setup.ranks.map { Set($0) == members } ?? false) }
        let builds = Dictionary(pair.members.map { ($0.id, $0.runtimeBinarySHA256) }, uniquingKeysWith: { first, _ in first })
        let figures = ClusterServedModes.figures(ClusterServedSpeedRecords.servedAs(serving, tensorAssistant: tensorAssistant,
                                                     ClusterServedSpeedRecords.servedBy(builds, pairServed).current),
                                                 promptTokens: result.promptTokens, outputTokens: result.outputTokens)
        let earlier = earlierFigures(pairServed, builds: builds, serving: serving, tensorAssistant: tensorAssistant,
                                     promptTokens: result.promptTokens, outputTokens: result.outputTokens)
        var families = Set<ClusterForcedMode>(), modes = [ClusterSetupPlanSummary.Mode]()
        for option in shards.options.sorted(by: { ($0.verdict == .chosen ? 0 : 1) < ($1.verdict == .chosen ? 0 : 1) })
            where runs.contains(option.verdict) {
            guard let mode = option.mode, let family = ClusterForcedMode.allCases.first(where: { $0.admits(mode) }),
                  families.insert(family).inserted else { continue }
            modes.append(.init(mode: mode.rawValue, shares: option.members.map {
                .init(local: $0.device == localMemberID, firstLayer: $0.firstLayer, endLayer: $0.endLayer, share: $0.share)
            }, servedDecodeTokensPerSecond: figures.first { $0.mode == mode }?.decodeTokensPerSecond,
               earlierServedDecodeTokensPerSecond: earlier[mode]))
        }
        return modes.isEmpty ? nil : modes
    }

    /// Each mode's decode rate as this pair last served it with an earlier worker build, which no plan of this build
    /// reads (`ClusterServedSpeedRecords.servedBy`), so that the mode question still ranks the modes by what these Macs
    /// served right after an update (`ClusterOnboardingModeAdvice.advise`). Only records that name how they were served
    /// count, and only those served the way the plan will serve: `serving`, and tensor parallel with Qwen's tensor
    /// assistant exactly when `tensorAssistant` (a record written before either was recorded may have been served the
    /// other way: pair-2's Qwen decoded 34-36 tok/s locally with the assistant, 14-20 through Darkbloom without it). A
    /// mode's rate is the latest earlier build's that served it, read as one build's records are
    /// (`ClusterServedModes.figures`). `entries`: this model's records on these Macs, any build.
    static func earlierFigures(_ entries: [ClusterServedSpeedRecords.Entry], builds: [String: String], serving: ClusterServedScope,
                               tensorAssistant: Bool, promptTokens: Int, outputTokens: Int) -> [ClusterGenerationMode: Double] {
        let earlier = entries.filter { entry in
            let setup = entry.setup
            guard !setup.servedBy(builds), setup.serving == serving else { return false }
            return setup.mode != ClusterGenerationMode.tensorParallel.rawValue || setup.tensorAssistant == tensorAssistant
        }
        // Each build's records, the latest build first: by its newest request.
        let byBuild: [[String]: [ClusterServedSpeedRecords.Entry]] = Dictionary(grouping: earlier) { $0.setup.rankBuildSHA256 ?? [] }
        func newest(_ build: [String]) -> Double { byBuild[build]?.map(\.sample.finishedAt).max() ?? 0 }
        let latestFirst = byBuild.keys.sorted { newest($0) != newest($1) ? newest($0) > newest($1) : $0.lexicographicallyPrecedes($1) }
        var rates: [ClusterGenerationMode: Double] = [:]
        for build in latestFirst {
            for figure in ClusterServedModes.figures(byBuild[build] ?? [], promptTokens: promptTokens, outputTokens: outputTokens)
                where rates[figure.mode] == nil {
                rates[figure.mode] = figure.decodeTokensPerSecond
            }
        }
        return rates
    }

    static func summary(_ result: ClusterPlacementResult, chosen: ClusterPlacementCandidate, lines: [String], localMemberID: String,
                        profiles: [String: ClusterDeviceProfile]) -> ClusterSetupPlanSummary {
        let prediction = chosen.prediction(result.regime)
        let ranks = chosen.ranks.map { rank in
            ClusterSetupPlanSummary.Rank(rank: rank.rank, memberID: rank.device, local: rank.device == localMemberID,
                firstLayer: rank.firstLayer, endLayer: rank.endLayer, weightsBytes: rank.weightsBytes, needBytes: rank.needBytes,
                admissibleNowBytes: rank.admissibleNowBytes, physicalMemoryBytes: profiles[rank.device]?.physicalMemoryBytes ?? 0,
                fit: fitCode(rank.fit), fitDetail: fitWords(rank.fit, device: rank.device), shortBytes: shortBytes(rank.fit))
        }
        let alone = result.alone.map { a in
            ClusterSetupPlanSummary.Alone(memberID: a.device, fitsNow: a.fit == .now, holds: a.fit.possible,
                firstTokenSeconds: a.prediction(result.regime).firstTokenSeconds,
                decodeTokensPerSecond: a.prediction(result.regime).decodeTokensPerSecond)
        }
        return .init(cut: chosen.cut, mode: chosen.mode.rawValue, prefillSchedule: chosen.prefillSchedule.rawValue,
            leaderID: chosen.ranks.first?.device ?? localMemberID, ranks: ranks, promptTokens: result.promptTokens,
            outputTokens: result.outputTokens, firstTokenSeconds: prediction.firstTokenSeconds,
            decodeTokensPerSecond: prediction.decodeTokensPerSecond, absolute: result.basis.absolute,
            measured: result.basis.source == .measured, alone: alone, aloneAsFast: result.aloneAsFast,
            fitsNow: ranks.allSatisfy { $0.fit == "now" }, needsBytes: ranks.compactMap(\.shortBytes).max(), explanation: lines,
            modeReason: ClusterPlacementExplanation.deploymentReason(result),
            tensorParallelNote: ClusterPlacementExplanation.tensorParallelNote(result)?.rawValue)
    }

    static func fitCode(_ fit: ClusterPlacementFit) -> String {
        switch fit {
        case .now: return "now"
        case .gateCountsLess: return "gateCountsLess"
        case .afterApplicationsRelease: return "afterApplicationsRelease"
        case .afterRestart: return "afterRestart"
        case .never: return "never"
        }
    }

    static func shortBytes(_ fit: ClusterPlacementFit) -> Int? {
        switch fit {
        case .now: return nil
        case .gateCountsLess(let bytes), .afterApplicationsRelease(let bytes), .afterRestart(let bytes): return bytes
        case .never(let bytes): return bytes
        }
    }

    static func fitWords(_ fit: ClusterPlacementFit, device: String) -> String {
        switch fit {
        case .now: return "fits now"
        case .gateCountsLess(let bytes):
            return "\(device) has the memory, but the load gate counts \(ClusterSetupScreen.gib(bytes)) less of its file cache than the kernel would give; nothing has to close"
        case .afterApplicationsRelease(let bytes):
            return "\(device) needs \(ClusterSetupScreen.gib(bytes)) more free: quit applications there first"
        case .afterRestart(let bytes):
            return "\(device) is \(ClusterSetupScreen.gib(bytes)) short even with every application closed: the kernel keeps that much file cache as its minimum (a share of the memory that is not wired), which closing applications does not lower; a restart empties the cache"
        case .never(let bytes):
            return "\(device) cannot hold this range: \(ClusterSetupScreen.gib(bytes)) short of what it has at all"
        }
    }
}

/// A failure's text, carried as a value.
struct ClusterSetupFailure: Error, Sendable, Equatable {
    let text: String
    init(_ text: String) { self.text = ClusterConsoleText.bounded(text, maximum: 240) }
    init(_ error: Error) { self.init(String(describing: error)) }
}

extension ClusterPairDescription {
    /// The coordinator and link control ports this description names.
    var ports: ClusterSetupPorts.Choice {
        .init(coordinator: UInt16(clamping: coordinatorPort), linkControl: UInt16(clamping: linkControl?.port ?? Int(ClusterSetupPorts.conventionalLinkControl)))
    }

    /// The same description naming other ports.
    func withPorts(_ ports: ClusterSetupPorts.Choice) -> ClusterPairDescription {
        var value = ClusterPairDescription(schema: schema, clusterID: clusterID, publicModelID: publicModelID, capabilitySHA256: capabilitySHA256,
            chunkTokens: chunkTokens, requestTimeoutSeconds: requestTimeoutSeconds, coordinatorPort: Int(ports.coordinator), members: members,
            tokenizerFiles: tokenizerFiles)
        value.linkControl = linkControl.map { .init(port: Int(ports.linkControl), linkEpoch: $0.linkEpoch, edgeID: $0.edgeID) }
        return value
    }
}
