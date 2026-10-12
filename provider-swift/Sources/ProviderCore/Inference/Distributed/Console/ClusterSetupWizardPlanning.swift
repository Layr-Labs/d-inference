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
    static func pairDescription(_ base: ClusterPairDescription, folder: String, publicModelID: String, capabilitySHA256: String,
                            tokenizerFiles: [ClusterConfiguration.TokenizerFile]) -> ClusterPairDescription {
        ClusterPairDescription(schema: base.schema, clusterID: base.clusterID, publicModelID: publicModelID,
            capabilitySHA256: capabilitySHA256, chunkTokens: base.chunkTokens, requestTimeoutSeconds: base.requestTimeoutSeconds,
            coordinatorPort: base.coordinatorPort,
            members: base.members.map { member in
                let directory = URL(fileURLWithPath: member.modelDirectory).deletingLastPathComponent().appendingPathComponent(folder).path
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
                       measurements: [ClusterSpeedMeasurement], leader: String?? = .none) -> [Decision] {
        // The wizard's own steps lead from this Mac; the onboarding (`nil`) leaves which Mac leads the
        // session (rank 0) and which decodes to the planner and the model's pair-serving grant.
        let sessionLeader: String? = leader ?? localMemberID
        let peerID = description.members.first { $0.id != localMemberID }?.id ?? "the other Mac"
        return readings.map { reading in
            let onOther = peerModels.contains { $0.artifactSHA256 == reading.model.artifactSHA256 }
            func blocked(_ reason: String) -> Decision {
                .init(option: .init(model: reading.model, onOtherMac: onOther, blocker: reason, plan: nil), setup: nil, capability: nil)
            }
            guard onOther else { return blocked("not on \(peerID): copy it there first") }
            let layout: ClusterModelLayout
            switch reading.layout {
            case .success(let value): layout = value
            case .failure(let error): return blocked("the planner cannot read this model's layers yet (\(error.text))")
            }
            let capability: (record: ClusterRuntimeCapability, data: Data, sha256: String)
            switch reading.capability {
            case .success(let value): capability = value
            case .failure(let error): return blocked("this build's cluster runtime does not run it (\(error.text))")
            }
            guard !reading.tokenizerFiles.isEmpty else { return blocked("its manifest names no tokenizer file") }
            let pair = pairDescription(description, folder: reading.model.folder, publicModelID: reading.model.modelID,
                capabilitySHA256: capability.sha256, tokenizerFiles: reading.tokenizerFiles)
            do {
                let decided = try ClusterPlacementFlow.decide(description: pair, capability: capability.record, localMemberID: localMemberID,
                    localProfile: localProfile, peerProfile: peerProfile, layout: layout, measurements: measurements, leader: sessionLeader)
                guard let chosen = decided.result.chosen else {
                    return blocked(refusalWords(decided.result, localMemberID: localMemberID))
                }
                let plan = summary(decided.result, chosen: chosen, lines: decided.lines, localMemberID: localMemberID,
                    profiles: [localMemberID: localProfile, peerID: peerProfile])
                return .init(option: .init(model: reading.model, onOtherMac: true, blocker: nil, plan: plan), setup: decided.setup,
                    capability: (capability.data, capability.sha256))
            } catch {
                return blocked("planning failed (\(ClusterConsoleText.bounded(String(describing: error), maximum: 200)))")
            }
        }
    }

    static func refusalWords(_ result: ClusterPlacementResult, localMemberID: String) -> String {
        if let alone = result.alone.first(where: { $0.fit.possible }) {
            return "no split this Mac leads holds it, but \(alone.device) holds it alone: serve it on that Mac with `darkbloom start`"
        }
        if let refusal = result.refusal {
            let total = ClusterSetupScreen.gib(refusal.modelLoadedBytes)
            return "too large for this pair: it needs \(total) and no split fits even with every application closed"
        }
        return "no placement this Mac leads fits on this pair now"
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
            fitsNow: ranks.allSatisfy { $0.fit == "now" }, needsBytes: ranks.compactMap(\.shortBytes).max(), explanation: lines)
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
            return "\(device) is \(ClusterSetupScreen.gib(bytes)) short even with every application closed: only a restart frees the kernel's file cache"
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
