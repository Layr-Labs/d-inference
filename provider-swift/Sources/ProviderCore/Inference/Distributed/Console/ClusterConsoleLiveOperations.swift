import Foundation
import Darwin

/// The console's operations as the installed command runs them. Each one is
/// the function behind an existing `darkbloom cluster` subcommand, or a
/// read-only look at the same files and tools.
extension ClusterConsoleOperations {
    public struct LiveSettings: Sendable {
        /// The provider configuration the saved cluster reference is read from.
        public let providerConfiguration: URL
        public let candidate: ClusterConsoleCandidate?
        /// This executable, to start `start --local --distributed` with.
        public let darkbloomExecutable: URL
        public let sessionArguments: [String]
        /// Where the diagnostics export is written.
        public let exportDirectory: URL
        /// What a link fix from this screen would be, so the guided setup's
        /// sentences describe that fix.
        public let options: ClusterConsoleState.Options

        public init(providerConfiguration: URL, candidate: ClusterConsoleCandidate?, darkbloomExecutable: URL,
                    sessionArguments: [String], exportDirectory: URL, options: ClusterConsoleState.Options) {
            self.providerConfiguration = providerConfiguration; self.candidate = candidate
            self.darkbloomExecutable = darkbloomExecutable; self.sessionArguments = sessionArguments
            self.exportDirectory = exportDirectory; self.options = options
        }
    }

    public static func live(_ settings: LiveSettings) throws -> ClusterConsoleOperations {
        let paths = try ClusterUserPaths()
        let configuration = settings.providerConfiguration
        return ClusterConsoleOperations(
            snapshot: {
                // One link reading serves the screen and the doctor's checks.
                let link = ClusterLinkReadinessProbe.inspectLocalLink()
                let diagnostics = blocking { await ClusterDiagnostics.doctor(providerConfiguration: configuration, localLink: link) }
                return ClusterConsoleObserver.snapshot(link: link, diagnostics: diagnostics,
                    reference: Result { try ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: configuration) },
                    paths: paths, candidate: settings.candidate, temporary: settings.options.temporary,
                    dryRun: settings.options.dryRun)
            },
            inspectLink: { ClusterLinkReadinessProbe.inspectLocalLink() },
            observeSession: {
                let clean = ClusterConsoleFreeText(homeDirectory: paths.homeDirectory.path)
                return .init(status: blocking { await ClusterDiagnostics.status(providerConfiguration: configuration) }.cleaned(clean))
            },
            fixLink: { fix in
                ClusterConsoleObserver.result(ClusterLinkRepair.fix(device: fix.device,
                    mode: fix.temporary ? .temporary : .durable, dryRun: fix.dryRun))
            },
            recoverJournal: {
                do { return ClusterConsoleObserver.result(try ClusterDeviceRecovery.recover()) } catch { return .failure(error) }
            },
            approveSetup: { candidate, expectedSHA256 in
                do {
                    return ClusterConsoleObserver.approve(candidate, expectedSHA256: expectedSHA256,
                        holdingIn: try ClusterConsoleInstanceLock.userTemporaryDirectory()) { reviewed in
                            try ClusterConfigurationStore(paths: paths).configure(
                                configurationInput: reviewed.configurationInput, capabilityInput: reviewed.capabilityInput,
                                capabilitySHA256: candidate.capabilitySHA256, providerConfiguration: configuration)
                        }
                } catch { return .failure(error) }
            },
            exportDiagnostics: { input in
                do {
                    let redaction = ClusterDiagnosticRedaction(identifiers: ClusterConsoleOperations.localIdentifiers(
                        paths: paths, providerConfiguration: configuration, candidate: settings.candidate))
                    let file = try ClusterDiagnosticExport.write(input, redaction: redaction, directory: settings.exportDirectory)
                    // The directory is the one the command was run in; its path is not repeated here.
                    return .init(succeeded: true, lines: [
                        "Wrote \(file.lastPathComponent) in the directory this command was run in.",
                        "Addresses, host names, user names, serial numbers, keys and home-directory paths were removed. Read it before you share it."])
                } catch { return .failure(error) }
            },
            launchSession: { events in
                try ClusterConsoleSessionProcess.start(.init(executable: settings.darkbloomExecutable,
                    arguments: settings.sessionArguments), events: events)
            })
    }

    /// Everything known here that names this Mac, its user or a peer: the
    /// saved setup's and the candidate's. The peers are read loosely, so a
    /// setup the strict reader refuses still gives up its names to be removed.
    static func localIdentifiers(paths: ClusterUserPaths, providerConfiguration: URL,
                                 candidate: ClusterConsoleCandidate?) -> ClusterDiagnosticRedaction.Identifiers {
        var identifiers = ClusterDiagnosticRedaction.Identifiers(
            homeDirectories: [paths.homeDirectory.path, NSHomeDirectory()],
            userNames: [NSUserName(), NSFullUserName()],
            hostNames: hostNames(),
            serials: machineIdentifiers(),
            secrets: [LocalEndpoint.readToken(), AuthTokenStore.load()].compactMap { $0 })
        var setups = [candidate?.configurationInput].compactMap { $0 }
        if let reference = try? ClusterConfigurationStore.optionalInstalledReference(providerConfiguration: providerConfiguration) {
            setups.append(URL(fileURLWithPath: reference.configuration))
        }
        for setup in setups {
            let named = peerNames(inSetupAt: setup)
            identifiers.hostNames += named.hosts
            identifiers.userNames += named.users
        }
        return identifiers
    }

    /// The host names, addresses and user names a setup file gives its peers,
    /// and each host name's first label.
    static func peerNames(inSetupAt url: URL) -> (hosts: [String], users: [String]) {
        guard let data = try? Data(contentsOf: url), data.count <= ClusterConfigurationCodec.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        let peers = object["peers"] as? [[String: Any]] ?? []
        var hosts = peers.compactMap { $0["host"] as? String }
        // A name's first label is the name without its domain. An address has no such part.
        hosts += hosts.filter { $0.contains(where: \.isLetter) && !$0.contains(":") }
            .compactMap { $0.split(separator: ".").first.map(String.init) }
        if let address = (object["coordinator"] as? [String: Any])?["address"] as? String { hosts.append(address) }
        return (hosts, peers.compactMap { $0["user"] as? String })
    }

    private static func hostNames() -> [String] {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        var names = [ProcessInfo.processInfo.hostName]
        if gethostname(&buffer, buffer.count - 1) == 0 {
            names.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        // The first label is the name without its domain.
        names += names.filter { $0.contains(where: \.isLetter) }.compactMap { $0.split(separator: ".").first.map(String.init) }
        if let computer = Host.current().localizedName { names.append(computer) }
        return names
    }

    /// The serial number and hardware UUID, read to be removed and for nothing else.
    private static func machineIdentifiers() -> [String] {
        var values = [String]()
        if let uuid = ClusterLinkMachineIdentity.hardwareUUID() {
            values.append(uuid)
            let hex = Array(uuid)
            if hex.count == 32 {
                values.append([hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]].map { String($0) }.joined(separator: "-"))
            }
        }
        let registry = ClusterLinkToolProcess.run(executable: "/usr/sbin/ioreg", arguments: ["-rd1", "-c", "IOPlatformExpertDevice"],
            deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000, maximumOutputBytes: 256 * 1024)
        if case .output(let text) = registry, let serial = parseSerialNumberFromIOReg(text) { values.append(serial) }
        return values
    }
}

/// Runs an asynchronous operation to completion from a thread that is not part
/// of the cooperative pool. The console's work queue and the command's own
/// thread are such threads; the calling thread waits, so it must be one.
private func blocking<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) -> Value {
    let box = BlockingResult<Value>(), finished = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await operation()
        finished.signal()
    }
    finished.wait()
    return box.value!
}

private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}
