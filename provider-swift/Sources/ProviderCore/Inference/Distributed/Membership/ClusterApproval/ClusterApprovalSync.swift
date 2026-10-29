import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// The control leader's step that keeps both Macs' setups on the same cluster approval: after the guided setup saved
/// both setups, after an update re-adopted them, and once at each start of its cluster service. The leader asks its
/// coordinator, checks the entry against its own files, sends it to the other Mac over the cable (which checks it
/// against its files and saves it, or refuses), and saves it itself only after the other Mac did. Both Macs so carry
/// the approval, or neither does. A coordinator that offers none (404, any failure) changes nothing.
public enum ClusterApprovalSync {
    /// How the other Mac's refusal starts, so the leader's line names the Mac that refused.
    public static let peerRefusalPrefix = "the other Mac refused the cluster approval: "

    /// What the step did, for the screen, the service log and the status line.
    public struct Result: Equatable, Sendable {
        /// Whether a setup was saved on either Mac (the parts must start again from the new setups).
        public var changed: Bool
        /// One line for the screen and the log; nil when nothing changed and nothing is worth saying.
        public var line: String?
        /// The status note to record: `.some(nil)` clears it (offered), `.some(text)` says why the pair serves
        /// locally, nil leaves the record as it is (a coordinator that offers nothing writes nothing at all).
        public var note: String??

        static let unchanged = Result(changed: false, line: nil, note: nil)
    }

    /// The plain reason of an error, without its type's wrapping.
    public static func refusal(_ error: Error) -> String {
        if case .invalid(let text) = error as? ClusterConfigurationError { return text }
        if let failure = error as? ClusterSetupFailure { return failure.text }
        return "\(error)"
    }

    /// What the step would do with this saved setup and this answer.
    static func decision(saved: ClusterConfigurationStore.Saved, fetched: ClusterApprovalFetch.Outcome,
                         now: Double) -> ClusterApprovalLifetime.Decision {
        let configuration = saved.configuration
        // A pair approval an operator saved by hand (`darkbloom cluster configure`) is theirs to change.
        guard configuration.nativeMember?.approval == nil else { return .keep }
        return ClusterApprovalLifetime.decide(saved: configuration.nativeMember?.clusterApproval, fetched: fetched,
            model: configuration.publicModelID, schedule: configuration.selectedPrefillSchedule, now: now)
    }

    /// One run of the step. `sendToPeer` delivers an `approval` command over the cable and throws the other Mac's
    /// refusal. The parts of both Macs must be stopped (each save needs its device journal empty).
    static func run(fetched: ClusterApprovalFetch.Outcome, paths: ClusterUserPaths, providerConfiguration: URL,
                    pairingStore: ClusterPairingStore, scratch: URL, now: Double,
                    sendToPeer: (ClusterServiceCommand) throws -> Void,
                    chipClass: ClusterChipClass? = ClusterChipClass.local(),
                    facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = ClusterApprovalAttachment.installedFacts)
        -> Result {
        guard let saved = try? ClusterApprovalAttachment.savedSetup(paths: paths, providerConfiguration: providerConfiguration) else {
            return .unchanged
        }
        let configuration = saved.configuration
        let current = configuration.nativeMember?.clusterApproval
        func send(_ approval: ClusterRuntimeApproval?, edge: ClusterEdge?) throws {
            var command = ClusterServiceCommand(op: .approval)
            command.approval = approval; command.approvalEdge = edge
            try sendToPeer(command)
        }
        func saveHere(_ attachment: ClusterNativeMemberAttachment?) throws -> Bool {
            try ClusterApprovalAttachment.save(attachment, saved: saved, paths: paths, providerConfiguration: providerConfiguration,
                                               scratch: scratch)
        }
        /// Both Macs without an approval (the saved one ended): the other Mac first, as when saving one.
        func removeBoth(_ why: String) -> Result {
            var line = why + "; the pair serves on the leader's local API"
            do { try send(nil, edge: nil) } catch { line += " (the other Mac removes its copy at its next start)" }
            do { _ = try saveHere(nil) } catch { line += " (this Mac could not save its setup: \(refusal(error)))" }
            return Result(changed: true, line: line, note: .some(line))
        }
        switch decision(saved: saved, fetched: fetched, now: now) {
        case .keep:
            return .unchanged
        case .remove:
            return removeBoth("The cluster approval \(current?.id ?? "") expired at \(current?.notAfter ?? "")")
        case .save(let approval):
            // A refusal leaves a saved approval that is still current in place; one that ended is removed.
            func refused(_ reason: String) -> Result {
                if let current, !ClusterApprovalLifetime.current(current, now: now) {
                    return removeBoth("Not offered for pairing: \(reason)")
                }
                let line = "Not offered for pairing: \(reason)"
                return Result(changed: false, line: line, note: .some(line))
            }
            let attachment: ClusterNativeMemberAttachment, peerEdge: ClusterEdge?
            do {
                // The leader's one link measurement, once from each side: the other Mac's edge names this Mac.
                let paired = try ClusterApprovalAttachment.pairing(configuration, store: pairingStore)
                func edge(to pin: String) -> ClusterEdge? {
                    ClusterApprovalAttachment.measuredEdge(peerPin: pin, members: configuration.peers.map(\.id),
                                                           homeDirectory: paths.homeDirectory)
                }
                peerEdge = edge(to: paired.localPin)
                attachment = try ClusterApprovalAttachment.attachment(for: approval, saved: saved, paths: paths, pairingStore: pairingStore,
                    edge: edge(to: paired.pins.first { $0 != paired.localPin } ?? ""), now: now, chipClass: chipClass, facts: facts)
            } catch { return refused("this Mac's check refused it: \(refusal(error))") }
            do { try send(approval, edge: peerEdge) } catch {
                // The link exchange wraps the other Mac's own reason ("the other Mac refused: …").
                let reason = refusal(error)
                return refused(reason.range(of: peerRefusalPrefix).map { String(reason[$0.lowerBound...]) }
                               ?? "the other Mac did not answer over the cable (\(reason))")
            }
            do { _ = try saveHere(attachment) } catch {
                // The other Mac saved it: take it back there, so neither Mac offers the pair alone.
                try? send(current, edge: peerEdge)
                return refused("this Mac could not save its setup: \(refusal(error))")
            }
            let line = ClusterApprovalLifetime.offeredLine(approval)
            return Result(changed: true, line: line, note: .some(nil))
        }
    }

    /// The other Mac's side of `run`: an `approval` command its leader sent, checked against this Mac's own files
    /// and pairing before anything is saved (`ClusterApprovalAttachment.apply`). A refusal is thrown with
    /// `peerRefusalPrefix`, so the leader's line names the Mac that refused and why.
    static func receive(_ command: ClusterServiceCommand, paths: ClusterUserPaths, providerConfiguration: URL,
                        pairingStore: ClusterPairingStore, scratch: URL, now: Double, say: (String) -> Void,
                        chipClass: ClusterChipClass? = ClusterChipClass.local(),
                        facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts = ClusterApprovalAttachment.installedFacts)
        throws -> String {
        do {
            let line = try ClusterApprovalAttachment.apply(command.approval, edge: command.approvalEdge, paths: paths,
                providerConfiguration: providerConfiguration, pairingStore: pairingStore, scratch: scratch, now: now,
                chipClass: chipClass, facts: facts)
            say(line)
            return line
        } catch {
            let reason = refusal(error)
            say("did not save the cluster approval the leader sent: \(reason)")
            throw ClusterSetupFailure(peerRefusalPrefix + reason)
        }
    }

    /// The step from a thread of the onboarding or the cluster service: fetches this release's approvals from the
    /// provider configuration's coordinator first.
    static func runLive(paths: ClusterUserPaths, providerConfiguration: URL, pairingStore: ClusterPairingStore, scratch: URL,
                        sendToPeer: (ClusterServiceCommand) throws -> Void) -> Result {
        guard let coordinator = try? ConfigManager.loadOrDefaults(from: providerConfiguration).coordinator.url else { return .unchanged }
        return run(fetched: ClusterApprovalFetch.fetchBlocking(coordinatorURL: coordinator), paths: paths,
                   providerConfiguration: providerConfiguration, pairingStore: pairingStore, scratch: scratch,
                   now: Date().timeIntervalSince1970, sendToPeer: sendToPeer)
    }
}
