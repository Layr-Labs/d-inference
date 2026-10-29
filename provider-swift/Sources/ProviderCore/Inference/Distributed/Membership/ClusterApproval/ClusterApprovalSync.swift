import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// The control leader's step that keeps both Macs' setups on the same cluster approval: after the guided setup's Test
/// stage passed, once at each start of its cluster service and after an update re-adopted the setups, and every
/// minute while the pair is offered. The leader asks its coordinator, takes the entry whose digests are its own
/// facts, sends it to the other Mac over the cable (which checks it against its own files and saves it, or refuses),
/// and saves it itself only after the other Mac did. Both Macs so carry the approval, or neither does. A coordinator
/// that serves none (404, no matching entry, any failure) changes nothing.
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

    /// What the step would do with this saved setup and this answer. `facts` describes this Mac's installed app for
    /// the setup's model; it runs only when an entry must be chosen.
    static func decision(saved: ClusterConfigurationStore.Saved, fetched: ClusterApprovalFetch.Outcome, now: Double,
                         facts: (ClusterConfiguration) throws -> ClusterRuntimeApprovalFacts) -> ClusterApprovalLifetime.Decision {
        let configuration = saved.configuration
        // A pair approval an operator saved by hand (`darkbloom cluster configure`) is theirs to change.
        guard configuration.nativeMember?.approval == nil else { return .keep }
        return ClusterApprovalLifetime.decide(saved: configuration.nativeMember?.clusterApproval, fetched: fetched,
            model: configuration.publicModelID, schedule: configuration.selectedPrefillSchedule,
            facts: { try? facts(configuration) }, now: now)
    }

    /// `ClusterApprovalCheck.Step.serveLocally`: the other Mac saves its setup without the approval first, then this
    /// Mac; `line` says why, for the screen, the log and the status. When either Mac cannot save, both keep the
    /// approval (the other Mac gets it back and checks it again), so neither serves in another mode than the other,
    /// and the next check tries again. The parts of both Macs must be stopped.
    static func serveLocally(_ approval: ClusterRuntimeApproval, line: String, paths: ClusterUserPaths, providerConfiguration: URL,
                             pairingStore: ClusterPairingStore, scratch: URL,
                             sendToPeer: (ClusterServiceCommand) throws -> Void) -> Result {
        guard let saved = try? ClusterApprovalAttachment.savedSetup(paths: paths, providerConfiguration: providerConfiguration) else {
            return .unchanged
        }
        func stays(_ why: String) -> Result {
            Result(changed: false, line: "The pair stays registered for now (" + why + "); this is tried again at the next check", note: nil)
        }
        do { try sendToPeer(ClusterServiceCommand(op: .approval)) } catch {
            return stays("the other Mac could not be told to serve locally (\(refusal(error)))")
        }
        do {
            _ = try ClusterApprovalAttachment.save(nil, saved: saved, paths: paths, providerConfiguration: providerConfiguration,
                                                   scratch: scratch)
        } catch {
            let saveFailure = refusal(error)
            // The other Mac saved without it: give it back there, with the link it registers to this Mac.
            var back = ClusterServiceCommand(op: .approval)
            back.approval = approval
            back.approvalEdge = (try? ClusterApprovalAttachment.pairing(saved.configuration, store: pairingStore)).flatMap {
                ClusterApprovalAttachment.measuredEdge(peerPin: $0.localPin, members: saved.configuration.peers.map(\.id),
                                                       homeDirectory: paths.homeDirectory)
            }
            do { try sendToPeer(back) } catch {
                return stays("this Mac could not save its setup (\(saveFailure)), and giving the other Mac the approval back "
                    + "failed too (\(refusal(error))): the next check compares both Macs")
            }
            return stays("this Mac could not save its setup (\(saveFailure))")
        }
        return Result(changed: true, line: line, note: .some(line))
    }

    /// `ClusterApprovalCheck.Step.converge`: the other Mac's saved cluster approval differs from this Mac's (a lost
    /// reply, a failed give-back), so it is given this Mac's (`target`), which it checks against its own files, or
    /// none. When it refuses this Mac's, this Mac saves its setup without it too: both Macs carry the approval, or
    /// neither does. The parts of both Macs must be stopped.
    static func converge(_ target: ClusterRuntimeApproval?, paths: ClusterUserPaths, providerConfiguration: URL,
                         pairingStore: ClusterPairingStore, scratch: URL, sendToPeer: (ClusterServiceCommand) throws -> Void) -> Result {
        guard let saved = try? ClusterApprovalAttachment.savedSetup(paths: paths, providerConfiguration: providerConfiguration) else {
            return .unchanged
        }
        var command = ClusterServiceCommand(op: .approval)
        command.approval = target
        if target != nil {
            command.approvalEdge = (try? ClusterApprovalAttachment.pairing(saved.configuration, store: pairingStore)).flatMap {
                ClusterApprovalAttachment.measuredEdge(peerPin: $0.localPin, members: saved.configuration.peers.map(\.id),
                                                       homeDirectory: paths.homeDirectory)
            }
        }
        do { try sendToPeer(command) } catch {
            let reason = refusal(error)
            guard let target, let range = reason.range(of: peerRefusalPrefix) else {
                return Result(changed: false, line: "The other Mac's cluster approval differs from this Mac's, and it could not be "
                    + "given this Mac's (\(reason)): this is tried again at the next check", note: nil)
            }
            var line = "The other Mac's cluster approval differed from this Mac's, and " + String(reason[range.lowerBound...])
                + ": neither Mac carries cluster approval \(target.id) now; the pair serves on the leader's local API"
            do { _ = try ClusterApprovalAttachment.save(nil, saved: saved, paths: paths, providerConfiguration: providerConfiguration,
                                                        scratch: scratch) }
            catch { line += " (this Mac could not save its setup yet: \(refusal(error)))" }
            return Result(changed: true, line: line, note: .some(line))
        }
        let line = target.map { "The other Mac's cluster approval differed from this Mac's: both Macs now carry approval \($0.id)" }
            ?? "The other Mac's cluster approval differed from this Mac's: neither Mac carries one now"
        return Result(changed: true, line: line, note: nil)
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
        switch decision(saved: saved, fetched: fetched, now: now, facts: facts) {
        case .keep:
            return .unchanged
        case .remove:
            return removeBoth("The cluster approval \(current?.id ?? "") expired at \(current?.notAfter ?? "")")
        case .withdrawn:
            return removeBoth("The coordinator no longer lists cluster approval \(current?.id ?? "")")
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
            /// Gives the other Mac this Mac's setup back (it may have saved `approval`): the reason, plus what was left
            /// undone when the give-back failed too, which the next check finds by comparing both Macs' approvals.
            func givenBack(_ reason: String) -> String {
                do { try send(current, edge: peerEdge); return reason } catch {
                    return reason + "; giving the other Mac its setup back failed too (\(refusal(error))): the next check compares both Macs"
                }
            }
            do { try send(approval, edge: peerEdge) } catch {
                // The link exchange wraps the other Mac's own reason ("the other Mac refused: …"): it saved nothing.
                // Any other failure (a lost reply) may come after the other Mac saved it.
                let reason = refusal(error)
                if let range = reason.range(of: peerRefusalPrefix) { return refused(String(reason[range.lowerBound...])) }
                return refused(givenBack("the other Mac did not answer over the cable (\(reason))"))
            }
            do { _ = try saveHere(attachment) } catch {
                // The other Mac saved it: give its setup back, so neither Mac offers the pair alone.
                return refused(givenBack("this Mac could not save its setup: \(refusal(error))"))
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
}
