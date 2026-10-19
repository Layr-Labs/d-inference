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
    }

    /// One model's option, and the setups adopting it would write.
    struct Decision: Sendable {
        let option: ClusterSetupModelOption
        let setup: ClusterPlacementSetup?
        let capability: (data: Data, sha256: String)?
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
    /// route only this Mac holds.
    static func decide(readings: [ModelReading], description: ClusterPairDescription, localMemberID: String,
                       localProfile: ClusterDeviceProfile, peerProfile: ClusterDeviceProfile, peerModels: [ClusterSetupLocalModel],
                       measurements: [ClusterSpeedMeasurement], leader: String?? = .none,
                       served: [ClusterServedSpeedRecords.Entry] = [], link: ClusterLinkCosts = .unmeasured,
                       peerMayReceive: Bool = false) -> [Decision] {
        // The wizard's own steps lead from this Mac; the onboarding (`nil`) leaves which Mac leads the
        // session (rank 0) and which decodes to the planner and the model's pair-serving grant.
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
                var decided = try ClusterPlacementFlow.decide(description: pair, capability: capability.record, localMemberID: localMemberID,
                    localProfile: localProfile, peerProfile: peerProfile, layout: layout, measurements: measurements, leader: sessionLeader,
                    served: served, link: link)
                // Ports chosen on this Mac hold only when it leads; a plan the other Mac leads names the conventional ones.
                if let setup = decided.setup, setup.leaderID != localMemberID, pair.ports != ClusterSetupPorts.Choice.conventional {
                    decided = try ClusterPlacementFlow.decide(description: pair.withPorts(.conventional), capability: capability.record,
                        localMemberID: localMemberID, localProfile: localProfile, peerProfile: peerProfile, layout: layout,
                        measurements: measurements, leader: sessionLeader, served: served, link: link)
                }
                guard let chosen = decided.result.chosen else {
                    // Macs by chip and memory, as pairing shows them, never by member ID.
                    let names = [localMemberID: "\(localProfile.chip), \(localProfile.physicalMemoryBytes >> 30) GB",
                                 peerID: "\(peerProfile.chip), \(peerProfile.physicalMemoryBytes >> 30) GB"]
                    return blocked(refusalWords(decided.result, localMemberID: localMemberID, names: names))
                }
                // Offered only when each Mac's start would serve the chosen placement (the planner already keeps away
                // from the shapes that diverged on these chips, so this holds unless the two disagree).
                let chips = [localMemberID: benchChip ?? localProfile.chip, peerID: benchChip ?? peerProfile.chip]
                if let refusal = ClusterPairServingGrants.startRefusal(
                    chosen.ranks.map { chips[$0.device].flatMap { ClusterChipClass(chipName: $0) } },
                    cuts: chosen.cuts, mode: chosen.mode, runtimeModelID: capability.record.runtimeModelID,
                    publicModelID: reading.model.modelID, artifactSHA256: capability.record.artifactSHA256) {
                    return blocked("not served on this pair by this build: "
                        + ClusterConsoleText.bounded(refusal.description, maximum: 200))
                }
                var plan = summary(decided.result, chosen: chosen, lines: decided.lines, localMemberID: localMemberID,
                    profiles: [localMemberID: localProfile, peerID: peerProfile])
                plan.publicTraffic = ClusterPairServingGrants.publicTrafficLine(runtimeModelID: capability.record.runtimeModelID,
                    artifactSHA256: capability.record.artifactSHA256, mode: chosen.mode)
                return .init(option: .init(model: reading.model, onOtherMac: onOther, blocker: nil, plan: plan), setup: decided.setup,
                    capability: (capability.data, capability.sha256))
            } catch is ClusterPairServingRefusal {
                // No stage adapter of this build runs the model.
                return blocked(noStageAdapter)
            } catch where String(describing: error).contains(ClusterConfiguration.peerBuildDiffers) {
                return blocked(differentBuilds)
            } catch {
                return blocked("Planning failed (\(ClusterConsoleText.bounded(String(describing: error), maximum: 160))).")
            }
        }
    }

    /// The plain blocker for a model no cluster stage adapter of this build runs.
    static let noStageAdapter = "This build has no cluster stage adapter for this model."
    /// The plain blocker for a model folder the cluster cannot read or run (not a model, or a version of it the cluster
    /// runtime does not take).
    static let notClusterModel = "not supported on a cluster yet"
    /// The plain blocker when the two Macs' installed cluster workers differ: nothing can be planned on both until they match.
    static let differentBuilds = "the two Macs run different Darkbloom builds; install the same Darkbloom on both"
    /// The plain blocker when every placement these Macs can hold is a shape that diverged on these chips.
    static let everyShapeDiverged = "Every way these Macs can hold it diverged from its single-Mac reference on these chips."

    /// The owner's serving of the model is refused for this build: no cluster stage adapter runs it (independent of
    /// the Macs' chips and of its records). Time budgets are derived from the setup, never a per-model row.
    static func pairServingRefused(_ capability: ClusterRuntimeCapability, publicModelID: String) -> Bool {
        (try? ClusterPairServingGrants.ownerServing(runtimeModelID: capability.runtimeModelID, publicModelID: publicModelID,
                                                    artifactSHA256: capability.artifactSHA256)) == nil
    }

    /// Why a model is not offered, plain action or fact first (the screen cuts long reasons).
    static func refusalWords(_ result: ClusterPlacementResult, localMemberID: String, names: [String: String] = [:]) -> String {
        func name(_ device: String) -> String { names[device] ?? device }
        if let excluded = result.unqualifiedPossible, excluded > 0 {
            let alone = result.alone.first(where: { $0.fit.possible })
                .map { " \(name($0.device)) can serve it alone in single-Mac Darkbloom." } ?? ""
            return everyShapeDiverged + alone
        }
        if let alone = result.alone.first(where: { $0.fit.possible }) {
            return "\(name(alone.device)) can serve it alone in single-Mac Darkbloom."
        }
        if let refusal = result.refusal {
            let total = ClusterSetupScreen.gib(refusal.modelLoadedBytes)
            return "Too large for these Macs together: it needs \(total), even with every application closed."
        }
        return "Too large for these Macs together right now."
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
            modeReason: ClusterPlacementExplanation.deploymentReason(result))
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
