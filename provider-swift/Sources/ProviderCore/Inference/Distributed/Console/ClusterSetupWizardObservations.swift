import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProcess
import DarkbloomClusterProtocol

/// Turns what the existing probes return into the wizard's report values.
/// Every function here is a pure reading of an observation already made.
extension ClusterSetupLink {
    /// The probe's report, the Thunderbolt reading, and nothing else.
    init(report: ClusterLinkReadinessReport, thunderbolt: Result<ClusterSetupThunderbolt, Error>) {
        let active = report.devices.filter(\.portActive)
        // The port the probe's verdict is about: the first ready one, else the first active one.
        let port = active.first { $0.verdict == .ready } ?? active.first
        self.init(state: report.state.rawValue, guidance: report.guidance,
            port: port.map { device in
                let isolation = device.isolation
                return .init(device: device.device, interface: device.interface, verdict: device.verdict.rawValue,
                    bridge: device.bridge ?? isolation?.bridge, hasIPv4Address: device.interfaceHasIPv4Address,
                    gidPublished: device.ipv4MappedGIDPresent, isolated: isolation?.isolated,
                    findings: isolation?.findings.map(\.rawValue) ?? [], blockers: isolation?.blockers.map(\.rawValue) ?? [],
                    isolationGuidance: device.interface.flatMap { isolation?.guidance(interface: $0) },
                    hardwarePort: isolation?.hardwarePort)
            },
            portsDown: report.devices.count - active.count,
            thunderbolt: try? thunderbolt.get(),
            thunderboltError: { if case .failure(let error) = thunderbolt { return ClusterConsoleText.bounded(error) } else { return nil } }())
    }
}

extension ClusterSetupSaved {
    /// `generationMode` is the saved configuration's, which the console's labels do not carry.
    init(_ saved: ClusterConsoleSavedSetup, generationMode: String? = nil) {
        switch saved.state {
        case .notConfigured: self = .notConfigured
        case .unreadable: self.init(state: .unreadable, error: saved.error, setup: nil)
        case .loaded:
            guard let pairing = saved.pairing, let model = saved.model, let digest = saved.configurationSHA256 else {
                self.init(state: .unreadable, error: "The saved setup was read without its pairing or model.", setup: nil)
                return
            }
            self.init(state: .loaded, error: nil, setup: .init(digest: digest, pairing: pairing, model: model, installed: saved.installed,
                generationMode: generationMode))
        }
    }
}

extension ClusterSetupSetupSummary {
    init(digest: String, pairing: ClusterConsolePairing, model: ClusterConsoleSavedModel, installed: ClusterConsoleInstalled?,
         generationMode: String? = nil) {
        self.init(configurationSHA256: digest, clusterID: pairing.clusterID, memberID: pairing.memberID,
            role: pairing.role.rawValue, localRank: pairing.localRank, peerID: pairing.peerID, linkDevice: pairing.linkDevice,
            publicModelID: model.publicModelID, runtimeModelID: model.runtimeModelID, artifactSHA256: model.artifactSHA256,
            planSHA256: model.planSHA256, generationMode: generationMode ?? "",
            prefillSchedule: model.prefillSchedule,
            stages: model.stages.map { .init(rank: $0.rank, memberID: $0.peerID, firstLayer: $0.sourceLayerStart, endLayer: $0.sourceLayerEnd) },
            knownHostsPinMatches: pairing.trust.knownHostsPinMatches, identityFileUsable: pairing.trust.identityFileUsable,
            workerVerified: installed?.workerBinary.verified, progressGuard: installed?.hasProgressGuard,
            workerDetail: installed?.workerBinary.detail, filesPresent: installed?.artifactFiles?.present,
            filesExpected: installed?.artifactFiles?.expected, holdings: installed?.holdings?.line)
        // No SSH trust is pinned exactly when the setup reaches its follower over the link.
        overLink = pairing.trust.knownHostsPinSHA256.isEmpty
    }

    /// A setup read from its files, saved or waiting in the inbox.
    init(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability, digest: String) throws {
        try self.init(digest: digest, pairing: .init(configuration: configuration),
            model: .init(configuration: configuration, capability: capability), installed: nil,
            generationMode: configuration.selectedGenerationMode.rawValue)
    }
}

extension ClusterSetupMemoryGuard {
    init(_ decision: ClusterOrphanWiredGuard.Decision) {
        switch decision {
        case .clear(let wired, let baseline):
            self.init(decision: .clear, wiredBytes: Int(clamping: wired), baselineBytes: Int(clamping: baseline), detail: nil)
        case .refused(let message):
            let wired = ClusterOrphanWiredGuard.wiredBytes().map { Int(clamping: $0) }
            let baseline = Int(clamping: ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: ProcessInfo.processInfo.physicalMemory))
            self.init(decision: .refused, wiredBytes: wired, baselineBytes: baseline, detail: message)
        case .skipped(let why):
            let wired = ClusterOrphanWiredGuard.wiredBytes().map { Int(clamping: $0) }
            let baseline = Int(clamping: ClusterOrphanWiredGuard.idleBaselineBytes(physicalBytes: ProcessInfo.processInfo.physicalMemory))
            self.init(decision: .skipped, wiredBytes: wired, baselineBytes: baseline, detail: why)
        }
    }
}

extension ClusterSetupCheck {
    init(_ check: ClusterDiagnosticsReport.Check) {
        self.init(name: check.name, outcome: check.outcome.rawValue, detail: check.detail)
    }
}

/// The pairing code: six decimal digits from the follower's SSH host key.
/// The leader computes it from the key its setup pins, once an SSH connection
/// that checks that pin has succeeded; the follower, and a Mac that does not
/// know its role yet, from its own SSH server's key. The same Mac at both
/// ends gives the same code; a different key, the same code only by a
/// one-in-a-million chance.
///
/// The code names the mechanism only through `ClusterSetupPairingCode.basis`.
/// A ceremony that does not use SSH (S17) supplies the code another way and
/// the screens stay as they are.
public enum ClusterSetupPairingCodes {
    static let domain = "darkbloom-cluster-pairing-code-v1"
    /// The algorithm both ends use when nothing pins another.
    static let preferredAlgorithm = "ssh-ed25519"

    /// `fingerprint` as `ssh-keygen -l` prints it: `SHA256:` and unpadded base64.
    public static func code(fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data("\(domain)\n\(fingerprint)".utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let digits = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// The host key a code is computed from: the first host (not CA, not
    /// revoked) key of the given algorithm, else of the preferred one, else any.
    static func hostKey(in keys: [ClusterConsoleHostKey], algorithm: String? = nil) -> ClusterConsoleHostKey? {
        let hosts = keys.filter { $0.kind == .host }
        return hosts.first { $0.algorithm == algorithm } ?? hosts.first { $0.algorithm == preferredAlgorithm } ?? hosts.first
    }

    /// The leader's code: from the pinned known-hosts text of its setup.
    static func pinned(knownHosts text: String) -> ClusterSetupPairingCode? {
        guard let key = hostKey(in: ClusterConsoleHostKeys.fingerprints(knownHosts: text).keys) else { return nil }
        return .init(code: code(fingerprint: key.fingerprint), basis: .pinnedHostKey, algorithm: key.algorithm)
    }

    /// The follower's code: from its own SSH server's keys as `ssh-keyscan`
    /// prints them (the known-hosts line format), choosing the algorithm its
    /// setup pins, so both ends hash the same key.
    static func own(keyscan text: String, pinnedKnownHosts: String?) -> ClusterSetupPairingCode? {
        let pinned = pinnedKnownHosts.flatMap { hostKey(in: ClusterConsoleHostKeys.fingerprints(knownHosts: $0).keys) }
        guard let key = hostKey(in: ClusterConsoleHostKeys.fingerprints(knownHosts: text).keys, algorithm: pinned?.algorithm) else { return nil }
        return .init(code: code(fingerprint: key.fingerprint), basis: .ownHostKey, algorithm: key.algorithm,
            differsFromPin: pinned.map { $0.fingerprint != key.fingerprint } ?? false)
    }

    /// `ssh-keyscan -t` names an algorithm without its prefix: `ed25519`, `ecdsa`, `rsa`.
    static func keyscanType(_ algorithm: String) -> String? {
        if algorithm.hasPrefix("ecdsa-") { return "ecdsa" }
        switch algorithm {
        case "ssh-ed25519": return "ed25519"
        case "ssh-rsa": return "rsa"
        default: return nil
        }
    }
}

/// Model folders beside a setup's model directory, read from their manifests.
enum ClusterSetupModelFolders {
    static let maximumFolders = 64

    /// Lists the folders of `parent` that hold a readable `manifest.json` with
    /// a model ID, a version and an aggregate digest. A folder whose manifest
    /// cannot be read is left out; nothing else in a folder is opened.
    static func list(parent: URL) throws -> [ClusterSetupLocalModel] {
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        var models = [ClusterSetupLocalModel]()
        for name in names.prefix(maximumFolders * 4) where !name.hasPrefix(".") {
            let manifest = parent.appendingPathComponent(name).appendingPathComponent("manifest.json")
            guard let data = readManifest(manifest), let model = parse(manifest: data, folder: name) else { continue }
            models.append(model)
            if models.count == maximumFolders { break }
        }
        return models
    }

    /// A model folder's manifest: a regular file (no symbolic link) of at most 1 MiB. Unlike setup and trust
    /// files it may be hard-linked (a model copied with links, a deduplicating copy): it names the model and
    /// its digests, and the worker verifies the weights against them before anything is served.
    static func readManifest(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1 << 20 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == Int(info.st_size) ? data : nil
    }

    static func parse(manifest data: Data, folder: String) -> ClusterSetupLocalModel? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["model_id"] as? String, let version = object["version"] as? String,
              let digest = object["aggregate_sha256"] as? String, ClusterConfigurationSyntax.hash(digest) else { return nil }
        let total = (object["total_size_bytes"] as? NSNumber)?.int64Value ?? 0
        // The files digest binds the names (a manifest that does not pass the catalog checks reports none).
        let files = (try? ClusterCatalogArtifact.parse(manifest: data))?.filesDigest
        return .init(folder: ClusterConsoleText.bounded(folder, maximum: 128), modelID: ClusterConsoleText.bounded(id, maximum: 128),
            version: ClusterConsoleText.bounded(version, maximum: 64), artifactSHA256: digest, totalBytes: total, filesSHA256: files)
    }
}
