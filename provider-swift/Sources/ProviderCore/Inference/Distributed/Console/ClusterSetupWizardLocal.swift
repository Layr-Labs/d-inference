import Foundation
import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Reads this Mac for the wizard: the same probes and files the cluster
/// subcommands read, put together as one report. It changes nothing.
enum ClusterSetupLocalReader {
    /// Why there is no profile on a Mac whose worker no setup names yet.
    static let noWorkerYet = "no setup names a worker yet"

    /// Longest any one child (plan tool, system_profiler, ssh-keyscan) may take.
    static let toolNanoseconds: UInt64 = 10_000_000_000

    /// Where this Mac's installation and models are, from the saved setup, a
    /// setup in the inbox, the pair description, or what the caller passes.
    struct Installation: Sendable, Equatable {
        var workerExecutable: String?
        var modelDirectory: String?
        var clusterID: String?
        /// The known-hosts file the setup pins, and the port this Mac's own SSH server listens on.
        var knownHostsFile: String?
        var sshPort: Int = 22
        /// This Mac leads (a saved leader setup, or the pair description it plans from): its
        /// code is the pinned key's. Every other Mac shows the code of its own host key.
        var leads: Bool = false
    }

    /// One report of this Mac. `doctor` and `version` come from the caller,
    /// which has the whole provider.
    static func report(link: ClusterLinkReadinessReport, doctor: [ClusterSetupCheck], version: String,
                       saved: ClusterConsoleSavedSetup, savedConfiguration: ClusterConfiguration?,
                       inbox: (summary: ClusterSetupSetupSummary?, configuration: ClusterConfiguration?, error: String?),
                       description: ClusterPairDescription?, localMemberID: String?, overrides: Installation = .init(),
                       journal: ClusterDeviceJournalObservation, now: Date = Date(), fallbackModelStore: URL? = nil) -> ClusterSetupReport {
        let installation = installation(saved: savedConfiguration, inbox: inbox.configuration, description: description,
            localMemberID: localMemberID, overrides: overrides)
        let mac = readMac(installation: installation)
        let thunderbolt = readThunderbolt()
        var models = [ClusterSetupLocalModel](), modelsError: String?
        // With no setup naming a folder, the cluster's own model store (no `--model-dir` needed).
        let store = installation.modelDirectory.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? fallbackModelStore
        if let store, FileManager.default.fileExists(atPath: store.path) || installation.modelDirectory != nil {
            do { models = try ClusterSetupModelFolders.list(parent: store) }
            catch { modelsError = ClusterConsoleText.bounded(error) }
        } else if store == nil {
            modelsError = "No setup or pair description names a model directory yet."
        }
        var report = ClusterSetupReport(observedAt: ClusterConsoleText.timestamp(now), version: version, mac: mac,
            link: .init(report: link, thunderbolt: thunderbolt), saved: .init(saved, generationMode: savedConfiguration?.selectedGenerationMode.rawValue),
            inbox: inbox.summary, inboxError: inbox.error,
            journal: journal, memoryGuard: .init(ClusterOrphanWiredGuard.evaluate(role: "wizard")), models: models,
            modelsError: modelsError, pairingCode: pairingCode(installation), checks: doctor,
            linkPairings: linkPairings(ClusterPairingStore.default()))
        report.modelStoreFreeBytes = store.flatMap(freeBytes)
        report.served = Array(ClusterServedSpeedHistory.entries(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .sorted { $0.sample.finishedAt > $1.sample.finishedAt }.prefix(ClusterSetupReport.servedShared))
        return report
    }

    /// Free bytes on the volume of `url` (or its nearest existing parent).
    static func freeBytes(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// The ceremony's store, as public values; nil when this Mac never paired.
    static func linkPairings(_ store: ClusterPairingStore) -> ClusterSetupLinkPairings? {
        do {
            guard let records = try store.load() else { return nil }
            return .init(localPin: String(records.localPin.prefix(16)), pairings: records.pairings.map {
                .init(peerPin: String($0.peerPin.prefix(16)), peerName: ClusterConsoleText.bounded($0.peerName, maximum: 96),
                      clusterID: ClusterConsoleText.bounded($0.clusterID, maximum: 128), generation: $0.roster.generation, pairedAt: $0.pairedAt)
            })
        } catch {
            return .init(localPin: "", pairings: [], error: ClusterConsoleText.bounded(error))
        }
    }

    static func installation(saved: ClusterConfiguration?, inbox: ClusterConfiguration?, description: ClusterPairDescription?,
                             localMemberID: String?, overrides: Installation) -> Installation {
        var value = Installation()
        if let configuration = saved ?? inbox {
            let local = configuration.peers[configuration.localRank]
            value = .init(workerExecutable: local.workerExecutable, modelDirectory: local.modelDirectory, clusterID: configuration.clusterID,
                knownHostsFile: configuration.trust?.knownHostsFile, sshPort: local.port, leads: configuration.role == .leader)
        } else if let description, let member = description.members.first(where: { $0.id == localMemberID }) {
            value = .init(workerExecutable: member.workerExecutable, modelDirectory: member.modelDirectory, clusterID: description.clusterID,
                knownHostsFile: member.trust?.knownHostsFile, sshPort: member.port, leads: true)
        }
        if let worker = overrides.workerExecutable { value.workerExecutable = worker }
        if let models = overrides.modelDirectory { value.modelDirectory = models }
        if let cluster = overrides.clusterID, value.clusterID == nil { value.clusterID = cluster }

        return value
    }

    // MARK: - Hardware

    static func readMac(installation: Installation) -> ClusterSetupMac {
        var profile: ClusterDeviceProfile?, profileError: String?
        if let worker = installation.workerExecutable {
            let tool = URL(fileURLWithPath: worker).deletingLastPathComponent().appendingPathComponent(ClusterPlacementFlow.toolName)
            do {
                profile = try ClusterDeviceProfile.decode(DistributedCapabilityProbe.run(executable: tool, arguments: ["device", "--json", "--index"],
                    deadline: DispatchTime.now().uptimeNanoseconds + toolNanoseconds, maximumOutputBytes: ClusterDeviceProfile.maximumEncodedBytes))
            } catch {
                profileError = "\(ClusterPlacementFlow.toolName) beside the worker: " + ClusterConsoleText.bounded(String(describing: error), maximum: 160)
            }
        } else {
            profileError = noWorkerYet
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        let volume = URL(fileURLWithPath: installation.modelDirectory.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? NSHomeDirectory())
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return .init(profile: profile, profileError: profileError, chip: profile?.chip ?? sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            physicalMemoryBytes: profile?.physicalMemoryBytes ?? Int(clamping: ProcessInfo.processInfo.physicalMemory),
            osVersion: profile.map { "\($0.osVersion) (\($0.osBuild))" } ?? osText, osMajor: os.majorVersion, osMinor: os.minorVersion,
            diskFreeBytes: values?.volumeAvailableCapacityForImportantUsage.map { Int(clamping: $0) },
            diskTotalBytes: values?.volumeTotalCapacity)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `system_profiler -json SPThunderboltDataType`: read-only, no privileges.
    static func readThunderbolt() -> Result<ClusterSetupThunderbolt, Error> {
        let result = ClusterLinkToolProcess.run(executable: "/usr/sbin/system_profiler", arguments: ["-json", "SPThunderboltDataType"],
            deadline: DispatchTime.now().uptimeNanoseconds + toolNanoseconds, maximumOutputBytes: 4 * 1024 * 1024)
        guard case .output(let text) = result else {
            return .failure(ClusterSetupFailure("system_profiler did not answer (\(result))"))
        }
        return Result { try ClusterSetupThunderbolt.parse(systemProfilerJSON: Data(text.utf8)) }
    }

    // MARK: - Pairing code

    /// The leader hashes the host key its setup pins; any other Mac its own
    /// SSH server's key, read the way any client would see it.
    static func pairingCode(_ installation: Installation) -> ClusterSetupPairingCode? {
        let pinned = installation.knownHostsFile.flatMap {
            try? ClusterConfigurationFiles.read(URL(fileURLWithPath: $0), maximum: 64 * 1024)
        }.flatMap { String(data: $0, encoding: .utf8) }
        if installation.leads { return pinned.flatMap { ClusterSetupPairingCodes.pinned(knownHosts: $0) } }
        let algorithm = pinned.flatMap { ClusterSetupPairingCodes.hostKey(in: ClusterConsoleHostKeys.fingerprints(knownHosts: $0).keys)?.algorithm }
            ?? ClusterSetupPairingCodes.preferredAlgorithm
        var arguments = ["-T", "3", "-p", String(installation.sshPort)]
        if let type = ClusterSetupPairingCodes.keyscanType(algorithm) { arguments += ["-t", type] }
        arguments.append("127.0.0.1")
        let result = ClusterLinkToolProcess.run(executable: "/usr/bin/ssh-keyscan", arguments: arguments,
            deadline: DispatchTime.now().uptimeNanoseconds + toolNanoseconds, maximumOutputBytes: 64 * 1024)
        guard case .output(let text) = result else { return nil }
        return ClusterSetupPairingCodes.own(keyscan: text, pinnedKnownHosts: pinned)
    }

    // MARK: - Pair

    /// What this Mac knows about its pair, most binding first: the saved
    /// setup, then a setup waiting in the inbox, then the pair description.
    static func pair(saved: ClusterConfiguration?, inbox: ClusterConfiguration?, description: ClusterPairDescription?,
                     localMemberID: String?) -> ClusterSetupPair? {
        if let configuration = saved ?? inbox {
            let local = configuration.peers[configuration.localRank], peer = configuration.peers[1 - configuration.localRank]
            return .init(source: saved != nil ? .saved : .inbox, clusterID: configuration.clusterID, localMemberID: local.id,
                peerMemberID: peer.id, leads: configuration.role == .leader, canReachPeer: configuration.role == .leader,
                modelFolder: URL(fileURLWithPath: local.modelDirectory).lastPathComponent, publicModelID: configuration.publicModelID)
        }
        guard let description, let local = description.members.first(where: { $0.id == localMemberID }),
              let peer = description.members.first(where: { $0.id != localMemberID }) else { return nil }
        return .init(source: .description, clusterID: description.clusterID, localMemberID: local.id, peerMemberID: peer.id,
            leads: nil, canReachPeer: true, modelFolder: URL(fileURLWithPath: local.modelDirectory).lastPathComponent,
            publicModelID: description.publicModelID)
    }

    /// The inbox's setup, read with the strict codecs, as a summary.
    static func inbox(_ store: ClusterSetupStore) -> (summary: ClusterSetupSetupSummary?, configuration: ClusterConfiguration?, error: String?) {
        guard let candidate = store.inboxCandidate else { return (nil, nil, nil) }
        do {
            let contents = try candidate.contents()
            return (try .init(configuration: contents.configuration, capability: contents.capability, digest: contents.configurationSHA256),
                contents.configuration, nil)
        } catch {
            return (nil, nil, ClusterConsoleText.bounded(error))
        }
    }
}
