import Foundation

public struct ClusterDiagnosticsReport: Encodable, Sendable {
    public enum ConfigurationState: String, Encodable, Sendable { case notConfigured, verified, invalid }
    public enum Outcome: String, Encodable, Sendable { case passed, failed, notRun, notObserved }
    public struct Check: Encodable, Sendable {
        public let name: String
        public let outcome: Outcome
        public let detail: String
    }
    public let schema = "darkbloom_cluster_diagnostics_v1"
    public let operation: String
    public let configurationState: ConfigurationState
    public let saved: ClusterStatusBinding?
    public let live: ClusterLiveStatus?
    public let deviceJournal: ClusterDeviceJournalObservation
    public let checks: [Check]
    /// These commands never run a new physical collective or change ownership.
    public let physicalProbePerformed = false
    public let recoveryPerformed = false
}

public enum ClusterDiagnostics {
    public static func status(providerConfiguration: URL) async -> ClusterDiagnosticsReport {
        await inspect(providerConfiguration: providerConfiguration, doctor: false)
    }

    /// Reuses the actual startup metadata validator, including the fixed bounded
    /// describe-runtime child. It performs no SSH, model load, matrix/config
    /// publication, lease acquisition, journal recovery or inference request.
    public static func doctor(providerConfiguration: URL) async -> ClusterDiagnosticsReport {
        await inspect(providerConfiguration: providerConfiguration, doctor: true)
    }

    private struct Saved: Sendable {
        let paths: ClusterUserPaths
        let reference: ClusterConfigurationReference?
        let binding: ClusterStatusBinding?
    }

    private static func inspect(providerConfiguration: URL, doctor: Bool) async -> ClusterDiagnosticsReport {
        var checks = [ClusterDiagnosticsReport.Check]()
        let operation = doctor ? "doctor" : "status"
        let saved: Saved
        do {
            saved = try await Task.detached {
                let paths = try ClusterUserPaths()
                let reference = try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: providerConfiguration)
                let loaded = try reference.map { try ClusterConfigurationStore(paths: paths).load(reference: $0) }
                let binding = try loaded.map { try ClusterStatusBinding(configuration: $0.configuration, capability: $0.capability) }
                return Saved(paths: paths, reference: reference, binding: binding)
            }.value
        } catch {
            return .init(operation: operation, configurationState: .invalid, saved: nil, live: nil,
                deviceJournal: (try? ClusterUserPaths()).map { .read(paths: $0) } ?? .unsafeOrChanging,
                checks: [.init(name: "savedConfiguration", outcome: .failed, detail: bounded(error))])
        }
        let journal = ClusterDeviceJournalObservation.read(paths: saved.paths)
        guard let binding = saved.binding, let reference = saved.reference else {
            return .init(operation: operation, configurationState: .notConfigured, saved: nil, live: nil,
                deviceJournal: journal, checks: [.init(name: "savedConfiguration", outcome: .notRun,
                    detail: "No saved cluster reference; ordinary solo behavior is unchanged.")])
        }
        checks.append(.init(name: "savedConfiguration", outcome: .passed,
            detail: "Canonical configuration/capability pins and selected policy verified; this is not readiness."))
        if doctor {
            do {
                try await Task.detached {
                    _ = try DistributedInstalledValidation.validate(reference: reference, paths: saved.paths,
                        deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
                }.value
                checks.append(.init(name: "localInstalledMetadata", outcome: .passed,
                    detail: "Local worker hash, config/manifest/tokenizer pins, trust-file metadata/pin and installed runtime description verified. Weight payloads and SSH authentication were not tested."))
            } catch {
                checks.append(.init(name: "localInstalledMetadata", outcome: .failed, detail: bounded(error)))
            }
        } else {
            checks.append(.init(name: "localInstalledMetadata", outcome: .notRun, detail: "Run cluster doctor for local installed metadata checks."))
        }
        var live: ClusterLiveStatus?
        if binding.role == .leader {
            do {
                live = try await ClusterStatusClient.observe(binding: binding, discoveryURL: LocalEndpoint.infoPath())
                checks.append(.init(name: "localServingObservation", outcome: .passed,
                    detail: live!.authenticationConfigured
                        ? "Fresh nonce-bound local response under configured bearer authentication."
                        : "Fresh nonce-bound local response; this server explicitly has no authentication configured."))
            } catch {
                checks.append(.init(name: "localServingObservation", outcome: .notObserved, detail: bounded(error)))
            }
        } else {
            checks.append(.init(name: "localServingObservation", outcome: .notRun,
                detail: "This member is a follower; run cluster status on the leader for its serving-session observation."))
        }
        checks.append(.init(name: "peerAndCollectiveProbe", outcome: .notRun,
            detail: live?.session.observedMembershipEpoch != nil
                ? "The retained leader reports bilateral loaded readiness for the displayed epoch. No new SSH, physical collective, numerical or throughput probe ran."
                : "No live loaded cohort observed. Peer installation, authenticated connectivity and physical collectives remain untested."))
        checks.append(.init(name: "deviceExclusion", outcome: .notRun,
            detail: "Journal metadata only. Nonempty means ownership is unproven, not orphaned; empty/absent is not a free-device proof. No lock or journal was changed."))
        return .init(operation: operation, configurationState: .verified, saved: binding, live: live,
            deviceJournal: journal, checks: checks)
    }

    private static func bounded(_ error: Error) -> String {
        String(String(describing: error).filter { character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        }.prefix(512))
    }
}
