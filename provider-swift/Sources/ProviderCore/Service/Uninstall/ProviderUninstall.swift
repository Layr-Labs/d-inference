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
    }

    /// How a step ended when it did not throw.
    public enum Outcome: Equatable, Sendable {
        case done(String? = nil)
        case skipped(String)
    }

    public struct Step: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case done, skipped, failed }
        public let name: String
        public let status: Status
        public let detail: String?
    }

    /// Everything a run touches outside this file, so that checks can run it on a fake home with no launchd.
    public struct Operations {
        /// Drains and stops the provider, as `darkbloom stop` does.
        public var stopServing: () async throws -> Outcome
        /// Stops this Mac's part of a pair and removes the cluster service, as `darkbloom cluster stop` does.
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
    }

    static let stopServingStep = "Stop serving on this Mac"
    static let clusterStep = "Stop this Mac's cluster part and remove its service"
    static let tokenStep = "Revoke this Mac's account token"
    static let cableStep = "Undo the cable port setup"
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
        let serving = await step(stopServingStep, operations.stopServing)
        var servicesStopped = await step(clusterStep, operations.stopClusterPart) && serving
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
        if let pairing {
            for peer in pairing.peers {
                _ = await step("Forget the pairing with \(peer.name)") { try operations.forget(peer.pin); return .done() }
            }
        } else {
            steps.append(.init(name: "Forget this Mac's pairing", status: .skipped, detail: "this Mac is not paired"))
        }
        // After the pairing, which tells the other Mac over the cable; this takes the cable's address away.
        let cableUndone = await step(cableStep, operations.removeCableSetup)
        let before = operations.availableBytes()
        for item in items where item.verdict != .keep && !(mode == .keepModels && item.kind == .model) {
            let name = "Delete \(item.label)"
            guard item.verdict == .remove else {
                steps.append(.init(name: name, status: .skipped, detail: "refused: \(item.reason ?? "outside Darkbloom's folders")"))
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
                try operations.delete(URL(fileURLWithPath: item.path))
                return .done(item.bytes > 0 ? formatBytes(item.bytes) : nil)
            }
        }
        return Report(mode: mode, steps: steps, availableBefore: before, availableAfter: operations.availableBytes())
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
