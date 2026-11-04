import Foundation

/// `darkbloom uninstall`: takes Darkbloom off this Mac. Both ways stop serving, remove every background service,
/// revoke the account token (best effort), unpair, undo the cable port setup and delete Darkbloom's folders
/// (`ProviderUninstallPaths`), the app last. `keepModels` keeps the model folders Darkbloom downloaded and the
/// cluster model store, so a reinstall finds them. Nothing in the Keychain is touched. Each step is idempotent; a
/// failed one is reported and the safe ones after it still run.
public enum ProviderUninstall {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case everything
        case keepModels = "keep-models"

        /// The one difference between the two: `keepModels` keeps every `.model` item in place.
        func keeps(_ item: ProviderUninstallItem) -> Bool { self == .keepModels && item.kind == .model }
    }

    /// How a step ended when it did not throw.
    public enum Outcome: Equatable, Sendable {
        case done(String? = nil)
        case skipped(String)
    }

    public struct Step: Sendable, Equatable {
        public enum Status: String, Sendable { case done, skipped, failed }
        public let name: String
        public let status: Status
        public let detail: String?
    }

    /// Everything a run touches outside this file, so that checks can run it on a fake home with no launchd.
    public struct Operations {
        /// Drains and stops the provider, as `darkbloom stop` does.
        public var stopServing: () async throws -> Outcome
        /// Stops this Mac's part of a pair and removes the cluster service, as `darkbloom cluster stop --service` does.
        public var stopClusterPart: () async throws -> Outcome
        /// The provider, watchdog and desktop API launch agents, by name, as `darkbloom stop --uninstall` removes them.
        public var removeServices: [(name: String, remove: () throws -> Outcome)]
        /// Called once the services are handled, before any account, pairing or file changes (releases the drain's lease).
        public var servicesHandled: () -> Void
        /// Revokes the saved account token as `darkbloom logout` does. Best effort: it reports, it never fails.
        public var revokeToken: () async -> Outcome
        /// `darkbloom cluster pair --forget <pin>`.
        public var forget: (_ peerPin: String) throws -> Void
        /// `darkbloom cluster link --remove`.
        public var removeCableSetup: () throws -> Outcome
        public var delete: (URL) throws -> Void
        /// Free bytes on the home volume, to report the space freed.
        public var availableBytes: () -> Int64?

        public init(stopServing: @escaping () async throws -> Outcome, stopClusterPart: @escaping () async throws -> Outcome,
                    removeServices: [(name: String, remove: () throws -> Outcome)], servicesHandled: @escaping () -> Void = {},
                    revokeToken: @escaping () async -> Outcome,
                    forget: @escaping (String) throws -> Void, removeCableSetup: @escaping () throws -> Outcome,
                    delete: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                    availableBytes: @escaping () -> Int64? = { nil }) {
            self.stopServing = stopServing; self.stopClusterPart = stopClusterPart; self.removeServices = removeServices
            self.servicesHandled = servicesHandled; self.revokeToken = revokeToken; self.forget = forget
            self.removeCableSetup = removeCableSetup; self.delete = delete; self.availableBytes = availableBytes
        }
    }

    public struct Report: Sendable, Equatable {
        public let mode: Mode
        public let steps: [Step]
        public let availableBefore: Int64?
        public let availableAfter: Int64?
        public var failed: Bool { steps.contains { $0.status == .failed } }
        /// Something of Darkbloom's that was to go is still here: refused, or kept because an earlier step failed.
        /// A command link the installer did not make is not Darkbloom's, so leaving it leaves nothing of Darkbloom's.
        public var incomplete: Bool {
            steps.contains {
                $0.status == .skipped && $0.name.hasPrefix("Delete ") && $0.detail != "already gone"
                    && $0.detail != notRemoved(foreignLinkReason)
            }
        }
    }

    static let stopServingStep = "Stop serving on this Mac"
    static let clusterStep = "Stop this Mac's cluster part and remove its service"
    static let tokenStep = "Revoke this Mac's account token"
    static let cableStep = "Undo the cable port setup"
    static let forgetStep = "Forget this Mac's pairing"
    static let ownClusterStep = "Remove this install's cluster service"
    static let stillServingReason = "serving did not stop (see the failed step above)"
    static let servicesRunningReason = "a Darkbloom service may still be running (see the failed step above)"
    static let cableRetryReason =
        "kept, so the uninstall can run again and undo the cable port setup (it holds the app and the cable records)"

    /// Runs `mode`. `items` is `inventory(_:)`, read before anything changed; `announce` prints each step as it starts.
    public static func run(_ mode: Mode, items: [ProviderUninstallItem], pairing: ProviderUninstallPairing?,
                           operations: Operations, announce: (String) -> Void = { _ in }) async -> Report {
        var steps: [Step] = []
        func step(_ name: String, _ body: () async throws -> Outcome) async -> Bool {
            announce(name)
            do {
                switch try await body() {
                case .done(let detail): steps.append(.init(name: name, status: .done, detail: detail))
                case .skipped(let reason): steps.append(.init(name: name, status: .skipped, detail: reason))
                }
                return true
            } catch {
                steps.append(.init(name: name, status: .failed, detail: "\(error)"))
                return false
            }
        }
        // Another install on this Mac uses the same pair, pairing and cable port setup: they all stay with it.
        let sharedWith = items.lazy.compactMap(\.sharedWith).first
        let serving = await step(stopServingStep, operations.stopServing)
        let clusterHandled: Bool
        if let other = sharedWith, let own = items.lazy.compactMap(\.ownClusterAgent).first {
            clusterHandled = await step(ownClusterStep) { try removeOwnClusterAgent(own, keptFor: other) }
        } else {
            clusterHandled = await step(clusterStep, operations.stopClusterPart)
        }
        var servicesStopped = clusterHandled && serving
        for service in operations.removeServices {
            // As `stop --uninstall`: a provider that did not drain keeps its agents, so nothing interrupts it.
            guard serving else {
                steps.append(.init(name: service.name, status: .skipped, detail: stillServingReason))
                continue
            }
            servicesStopped = await step(service.name, service.remove) && servicesStopped
        }
        operations.servicesHandled()
        // As `darkbloom logout`: only once the provider holding the token has stopped.
        if serving {
            _ = await step(tokenStep) { await operations.revokeToken() }
        } else {
            steps.append(.init(name: tokenStep, status: .skipped, detail: stillServingReason))
        }
        let keptForOther = sharedWith.map { "kept: \($0) on this Mac also uses it" }
        if pairing != nil, let keptForOther {
            steps.append(.init(name: forgetStep, status: .skipped, detail: keptForOther))
        } else if let pairing {
            for peer in pairing.peers {
                _ = await step("Forget the pairing with \(peer.name)") { try operations.forget(peer.pin); return .done() }
            }
        } else {
            steps.append(.init(name: forgetStep, status: .skipped, detail: "this Mac is not paired"))
        }
        // After the pairing, which tells the other Mac over the cable; this takes the cable's address away.
        let cableUndone: Bool
        if let keptForOther {
            steps.append(.init(name: cableStep, status: .skipped, detail: keptForOther))
            cableUndone = true
        } else {
            cableUndone = await step(cableStep, operations.removeCableSetup)
        }
        let before = operations.availableBytes()
        for item in items where item.verdict != .keep && !mode.keeps(item) {
            let name = "Delete \(item.label)"
            guard item.verdict == .remove else {
                steps.append(.init(name: name, status: .skipped, detail: notRemoved(item.reason ?? "outside Darkbloom's folders")))
                continue
            }
            guard servicesStopped else {
                steps.append(.init(name: name, status: .skipped, detail: servicesRunningReason))
                continue
            }
            guard cableUndone || item.kind != .command else {
                steps.append(.init(name: name, status: .skipped, detail: cableRetryReason))
                continue
            }
            _ = await step(name) {
                // The install folder holds the app this command runs from; it is deleted last. macOS keeps a
                // running executable's image after its file is unlinked, and nothing after this loads from it.
                guard FileManager.default.fileExists(atPath: item.path) || isLink(item.path) else { return .skipped("already gone") }
                if item.keeping.isEmpty {
                    try operations.delete(URL(fileURLWithPath: item.path))
                } else {
                    try deleteAround(URL(fileURLWithPath: ProviderUninstallPaths.canonical(item.path)), keeping: item.keeping,
                                     operations.delete)
                }
                return .done(item.bytes > 0 ? formatBytes(item.bytes) : nil)
            }
        }
        return Report(mode: mode, steps: steps, availableBefore: before, availableAfter: operations.availableBytes())
    }

    /// Deletes everything in `folder` except `keeping` (resolved paths inside it) and the folders that lead to them.
    /// An app bundle goes last, as the install folder's app does when the folder goes whole.
    static func deleteAround(_ folder: URL, keeping: [String], _ delete: (URL) throws -> Void) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .sorted { ($0.hasSuffix(".app") ? 1 : 0, $0) < ($1.hasSuffix(".app") ? 1 : 0, $1) }
        for name in names {
            let child = folder.appendingPathComponent(name)
            guard !keeping.contains(child.path) else { continue }
            let inside = keeping.filter { $0.hasPrefix(child.path + "/") }
            if inside.isEmpty { try delete(child) } else { try deleteAround(child, keeping: inside, delete) }
        }
    }

    static func notRemoved(_ reason: String) -> String { "not removed: \(reason)" }

    /// Step 2 beside another install that shares the pair: boots out and deletes only this install's own agent. The
    /// pair is not stopped and the other install's agent is not touched.
    static func removeOwnClusterAgent(_ label: String, keptFor other: String) throws -> Outcome {
        let leftAlone = "the pair and \(other)'s cluster service are left as they are"
        guard FileManager.default.fileExists(atPath: ClusterServiceAgent.plistPath(label: label).path)
                || ClusterServiceAgent.isLoaded(label: label) else { return .skipped("this install has none; \(leftAlone)") }
        try ClusterServiceAgent.remove(label: label)
        return .done("removed \(label); \(leftAlone)")
    }

    static func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// One launch agent: skipped when neither its file nor a loaded job exists, else removed by its own `uninstall`.
    public static func removeAgent(plist: URL, loaded: @autoclosure () -> Bool, uninstall: () throws -> Void) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: plist.path) || loaded() else { return .skipped("not installed") }
        try uninstall()
        return .done()
    }

    /// A step that ended without the wanted result, in a sentence.
    public struct StepFailure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
