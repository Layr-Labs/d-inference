import Foundation

public enum ClusterDiagnostics {
    public static func status(providerConfiguration: URL) async -> ClusterDiagnosticsReport {
        await inspect(providerConfiguration: providerConfiguration, doctor: false)
    }

    /// Reuses the actual startup metadata validator, including the fixed bounded
    /// describe-runtime child, and reads this Mac's own RDMA link state. It
    /// performs no SSH, model load, matrix/config publication, lease
    /// acquisition, journal recovery, collective or inference request.
    public static func doctor(providerConfiguration: URL) async -> ClusterDiagnosticsReport {
        await inspect(providerConfiguration: providerConfiguration, doctor: true)
    }

    /// The doctor over a link reading the caller has just taken, so a screen
    /// that shows both shows one reading.
    static func doctor(providerConfiguration: URL, localLink: ClusterLinkReadinessReport) async -> ClusterDiagnosticsReport {
        await inspect(providerConfiguration: providerConfiguration, doctor: true, observedLink: localLink)
    }

    private struct Saved: Sendable {
        let paths: ClusterUserPaths
        let reference: ClusterConfigurationReference?
        let binding: ClusterStatusBinding?
        /// The RDMA device the saved setup assigns to this Mac.
        let linkDevice: String?
    }

    private static func inspect(providerConfiguration: URL, doctor: Bool,
                                observedLink: ClusterLinkReadinessReport? = nil) async -> ClusterDiagnosticsReport {
        var checks = [ClusterDiagnosticsReport.Check]()
        let operation = doctor ? "doctor" : "status"
        // Only the doctor starts the link tools, so `cluster status` is no slower.
        let localLink: ClusterLinkReadinessReport?
        if let observedLink { localLink = observedLink } else {
            localLink = doctor ? await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value : nil
        }
        let saved: Saved
        do {
            saved = try await Task.detached {
                let paths = try ClusterUserPaths()
                let reference = try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: providerConfiguration)
                let loaded = try reference.map { try ClusterConfigurationStore(paths: paths).load(reference: $0) }
                let binding = try loaded.map { try ClusterStatusBinding(configuration: $0.configuration, capability: $0.capability) }
                let linkDevice = (loaded?.configuration).flatMap { configuration in
                    configuration.peers.first { $0.rank == configuration.localRank }?.jacclDevice
                }
                return Saved(paths: paths, reference: reference, binding: binding, linkDevice: linkDevice)
            }.value
        } catch {
            return .init(operation: operation, configurationState: .invalid, saved: nil, live: nil,
                deviceJournal: (try? ClusterUserPaths()).map { .read(paths: $0) } ?? .unsafeOrChanging,
                checks: [.init(name: "savedConfiguration", outcome: .failed, detail: bounded(error))],
                localLink: localLink, configuredLinkDevice: nil)
        }
        let journal = ClusterDeviceJournalObservation.read(paths: saved.paths)
        guard let binding = saved.binding, let reference = saved.reference else {
            return .init(operation: operation, configurationState: .notConfigured, saved: nil, live: nil,
                deviceJournal: journal, checks: [.init(name: "savedConfiguration", outcome: .notRun,
                    detail: "No saved cluster reference; ordinary solo behavior is unchanged.")],
                localLink: localLink, configuredLinkDevice: nil)
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
            detail: "Journal metadata only. Nonempty means ownership is unproven, not orphaned; empty/absent is not a free-device proof. No lock or journal was changed. `cluster recover` clears a journal whose owner and worker are both gone."))
        checks.append(.init(name: "nativeBootstrap", outcome: .notRun,
            detail: DistributedInstalledBootstrap.installed.ownerAuthenticated
                ? "Native ranks are started with the owner-authenticated bootstrap exchange."
                : "Native ranks are started with the runtime's own bootstrap exchange on the configured link address. The owner-authenticated exchange is not available in this build, so nothing vouches for the peer that answers on that address. Each rank is started with a \(DistributedInstalledPlan.collectiveProgressLimitMilliseconds) ms collective progress limit."))
        return .init(operation: operation, configurationState: .verified, saved: binding, live: live,
            deviceJournal: journal, checks: checks, localLink: localLink, configuredLinkDevice: saved.linkDevice)
    }

    private static func bounded(_ error: Error) -> String {
        String(String(describing: error).filter { character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        }.prefix(512))
    }
}
