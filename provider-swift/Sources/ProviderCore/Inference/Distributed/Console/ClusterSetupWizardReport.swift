import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// What one Mac reports about itself for the setup wizard: its hardware, its
/// cable, its saved setup and inbox, its models and its memory. The wizard on
/// this Mac draws from it, and the wizard on the other Mac asks for it over
/// the pinned SSH route (`darkbloom cluster report --json`), so both screens
/// show one Mac with the same words.
///
/// Names, counts, digests and verdicts only: no address, host name, user
/// name, serial number or path. A report from the other Mac is untrusted
/// input; `decode` bounds it and the screen sanitizes every string it shows.
public struct ClusterSetupReport: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_setup_report_v1"
    public static let maximumEncodedBytes = 256 * 1024

    public var schema = ClusterSetupReport.schemaName
    /// When this report was taken, in UTC.
    public var observedAt: String
    /// The Darkbloom build that took it.
    public var version: String
    public var mac: ClusterSetupMac
    public var link: ClusterSetupLink
    public var saved: ClusterSetupSaved
    /// A setup the leader sent this Mac and that it has not approved; nil when none waits.
    public var inbox: ClusterSetupSetupSummary?
    /// Why a setup in the inbox cannot be read; nil when there is none or it reads.
    public var inboxError: String?
    public var journal: ClusterDeviceJournalObservation
    public var memoryGuard: ClusterSetupMemoryGuard
    /// Model folders beside the model directory this Mac's setup names.
    public var models: [ClusterSetupLocalModel]
    /// Why the model folders were not listed; nil when they were.
    public var modelsError: String?
    /// This Mac's pairing code, when it can be worked out here.
    public var pairingCode: ClusterSetupPairingCode?
    /// The doctor's checks, as `darkbloom cluster doctor` reports them.
    public var checks: [ClusterSetupCheck]
    /// What this Mac pinned in the pairing ceremony over the link (S17); nil when it never paired.
    public var linkPairings: ClusterSetupLinkPairings?
    /// Free bytes on the disk of this Mac's model store (a copy of a model checks it before it starts); nil when unknown.
    public var modelStoreFreeBytes: Int64?
    /// The newest speed records of requests this Mac served as rank 0 (at most `servedShared`; nil from an older
    /// build). Only the Mac where requests enter keeps them, and the plan is made on the control leader, which is
    /// often the other Mac: without them a model measured on the pair was planned from the device index's estimate.
    public var served: [ClusterServedSpeedRecords.Entry]?
    public static let servedShared = 96

    public init(observedAt: String, version: String, mac: ClusterSetupMac, link: ClusterSetupLink, saved: ClusterSetupSaved,
                inbox: ClusterSetupSetupSummary?, inboxError: String? = nil, journal: ClusterDeviceJournalObservation, memoryGuard: ClusterSetupMemoryGuard,
                models: [ClusterSetupLocalModel], modelsError: String?, pairingCode: ClusterSetupPairingCode?,
                checks: [ClusterSetupCheck], linkPairings: ClusterSetupLinkPairings? = nil) {
        self.observedAt = observedAt; self.version = version; self.mac = mac; self.link = link; self.saved = saved
        self.inbox = inbox; self.inboxError = inboxError; self.journal = journal; self.memoryGuard = memoryGuard; self.models = models
        self.modelsError = modelsError; self.pairingCode = pairingCode; self.checks = checks; self.linkPairings = linkPairings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClusterSetupReport {
        guard (2...maximumEncodedBytes).contains(data.count) else {
            throw ClusterConfigurationError.invalid("The other Mac's report is empty or larger than \(maximumEncodedBytes) bytes")
        }
        let value = try JSONDecoder().decode(ClusterSetupReport.self, from: data)
        guard value.schema == schemaName else {
            throw ClusterConfigurationError.invalid("The other Mac answered with a report this build does not read (\(ClusterConsoleText.bounded(value.schema, maximum: 64)))")
        }
        return value
    }
}

/// This Mac's hardware, as the plan tool beside the worker detects it, with
/// the system's own figures standing in when that tool is not installed.
public struct ClusterSetupMac: Codable, Sendable, Equatable {
    /// The plan tool's profile: the host memory gate's own reading. Nil when the tool did not answer.
    public var profile: ClusterDeviceProfile?
    /// Why there is no profile; nil when there is one.
    public var profileError: String?
    /// `machdep.cpu.brand_string`.
    public var chip: String
    public var physicalMemoryBytes: Int
    public var osVersion: String
    /// macOS's version as numbers, for the minimum RDMA needs.
    public var osMajor: Int
    public var osMinor: Int
    /// Free space for important use on the volume that holds the models; nil when not read.
    public var diskFreeBytes: Int?
    public var diskTotalBytes: Int?

    public init(profile: ClusterDeviceProfile?, profileError: String?, chip: String, physicalMemoryBytes: Int,
                osVersion: String, osMajor: Int, osMinor: Int, diskFreeBytes: Int?, diskTotalBytes: Int?) {
        self.profile = profile; self.profileError = profileError; self.chip = chip
        self.physicalMemoryBytes = physicalMemoryBytes; self.osVersion = osVersion; self.osMajor = osMajor
        self.osMinor = osMinor; self.diskFreeBytes = diskFreeBytes; self.diskTotalBytes = diskTotalBytes
    }

    /// RDMA over Thunderbolt needs macOS 26.2 or later.
    public var osSupportsRDMA: Bool { osMajor > 26 || (osMajor == 26 && osMinor >= 2) }
}

/// The cable: the link probe's reading of the active RDMA port, what link
/// setup v2 finds around it, and the Thunderbolt connection behind it.
public struct ClusterSetupLink: Codable, Sendable, Equatable {
    public struct Port: Codable, Sendable, Equatable {
        public var device: String
        public var interface: String?
        /// The port's own verdict, a `ClusterLinkReadinessState` raw value.
        public var verdict: String
        public var bridge: String?
        public var hasIPv4Address: Bool?
        public var gidPublished: Bool?
        /// Nil when the network around the port was not read.
        public var isolated: Bool?
        /// `ClusterLinkIsolationFinding` raw values.
        public var findings: [String]
        /// The findings the one approval cannot cure.
        public var blockers: [String]
        /// What isolating the port takes, or what stands in the way, in the probe's words.
        public var isolationGuidance: String?
        /// macOS's name for the hardware port, such as "Thunderbolt 6".
        public var hardwarePort: String?
    }

    /// A `ClusterLinkReadinessState` raw value for the Mac as a whole.
    public var state: String
    public var guidance: String?
    /// The active RDMA port; nil when none is active.
    public var port: Port?
    public var portsDown: Int
    public var thunderbolt: ClusterSetupThunderbolt?
    public var thunderboltError: String?

    public init(state: String, guidance: String?, port: Port?, portsDown: Int, thunderbolt: ClusterSetupThunderbolt?,
                thunderboltError: String?) {
        self.state = state; self.guidance = guidance; self.port = port; self.portsDown = portsDown
        self.thunderbolt = thunderbolt; self.thunderboltError = thunderboltError
    }

    public var ready: Bool { state == ClusterLinkReadinessState.ready.rawValue }
    public var rdmaDisabled: Bool { state == ClusterLinkReadinessState.rdmaDisabled.rawValue }
    public var rdmaUnavailable: Bool { state == ClusterLinkReadinessState.rdmaUnavailable.rawValue }

    /// The Thunderbolt connection behind the active RDMA port, when it could be matched.
    public var clusterConnection: ClusterSetupThunderbolt.Receptacle? {
        guard let thunderbolt, let number = port?.hardwarePort.flatMap(ClusterSetupThunderbolt.receptacle(ofHardwarePort:)) else { return nil }
        return thunderbolt.receptacles.first { $0.id == number }
    }
}

/// The Mac's Thunderbolt receptacles as `system_profiler SPThunderboltDataType`
/// reports them: speed, whether something is connected and what it is.
public struct ClusterSetupThunderbolt: Codable, Sendable, Equatable {
    public enum Generation: String, Codable, Sendable {
        /// 80 Gb/s or more: a Thunderbolt 5 link, which RDMA needs at both ends.
        case thunderbolt5
        /// 40 Gb/s: Thunderbolt 4 or USB4 at one end or in the cable. RDMA does not run on it.
        case thunderbolt4
        /// Slower, or a speed this build cannot read.
        case slower
    }

    public struct Receptacle: Codable, Sendable, Equatable {
        /// The receptacle number, which is the N of the hardware port "Thunderbolt N".
        public var id: Int
        /// What the system prints: "80 Gb/s" for a live link, "Up to 120 Gb/s" for an idle port.
        public var speed: String
        public var connected: Bool
        /// The connected device's product name and model identifier, such as "Mac Studio", "Mac15,14".
        public var peerName: String?
        public var peerModel: String?

        public init(id: Int, speed: String, connected: Bool, peerName: String?, peerModel: String?) {
            self.id = id; self.speed = speed; self.connected = connected; self.peerName = peerName; self.peerModel = peerModel
        }

        /// The speed in Gb/s as printed, nil when it does not read as one.
        public var gigabits: Int? {
            let digits = speed.split(separator: " ").compactMap { Int($0) }
            return digits.first
        }

        /// What the live link is. Nil for a receptacle with nothing connected.
        public var generation: Generation? {
            guard connected, let gigabits else { return connected ? .slower : nil }
            return gigabits >= 80 ? .thunderbolt5 : gigabits >= 40 ? .thunderbolt4 : .slower
        }

        /// An idle receptacle that offers 80 Gb/s or more is a Thunderbolt 5 port.
        public var portIsThunderbolt5: Bool { (gigabits ?? 0) >= 80 }
    }

    public var receptacles: [Receptacle]

    public init(receptacles: [Receptacle]) { self.receptacles = receptacles }

    /// "Thunderbolt 6" names receptacle 6; anything else names none.
    public static func receptacle(ofHardwarePort name: String) -> Int? {
        let parts = name.split(separator: " ")
        guard parts.count == 2, parts[0] == "Thunderbolt" else { return nil }
        return Int(parts[1])
    }

    /// Reads `system_profiler -json SPThunderboltDataType`. Only the fields
    /// named above are kept: no unit identifier, route string or serial.
    public static func parse(systemProfilerJSON data: Data) throws -> ClusterSetupThunderbolt {
        guard data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = root["SPThunderboltDataType"] as? [[String: Any]] else {
            throw ClusterConfigurationError.invalid("system_profiler did not describe any Thunderbolt bus")
        }
        var receptacles = [Receptacle]()
        for bus in buses {
            guard let tag = bus["receptacle_1_tag"] as? [String: Any],
                  let idText = tag["receptacle_id_key"] as? String, let id = Int(idText) else { continue }
            let speed = (tag["current_speed_key"] as? String) ?? "unknown"
            let connected = (tag["receptacle_status_key"] as? String) == "receptacle_connected"
            let device = (bus["_items"] as? [[String: Any]])?.first
            receptacles.append(.init(id: id, speed: label(speed), connected: connected,
                peerName: (device?["_name"] as? String).map(label), peerModel: (device?["device_name_key"] as? String).map(label)))
        }
        return .init(receptacles: receptacles.sorted { $0.id < $1.id })
    }

    /// A printable label of bounded length.
    private static func label(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.prefix(48).map(Character.init))
    }
}

/// The saved setup, by labels and digests.
public struct ClusterSetupSaved: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case notConfigured, loaded, unreadable }
    public var state: State
    public var error: String?
    public var setup: ClusterSetupSetupSummary?

    public init(state: State, error: String?, setup: ClusterSetupSetupSummary?) {
        self.state = state; self.error = error; self.setup = setup
    }

    public static let notConfigured = ClusterSetupSaved(state: .notConfigured, error: nil, setup: nil)
}

/// One setup, saved or waiting for approval, by labels and digests.
public struct ClusterSetupSetupSummary: Codable, Sendable, Equatable {
    public struct Stage: Codable, Sendable, Equatable {
        public var rank: Int
        public var memberID: String
        public var firstLayer: Int
        public var endLayer: Int
    }
    public var configurationSHA256: String
    public var clusterID: String
    public var memberID: String
    /// `leader` or `follower`.
    public var role: String
    public var localRank: Int
    public var peerID: String
    public var linkDevice: String
    public var publicModelID: String
    public var runtimeModelID: String
    public var artifactSHA256: String
    public var planSHA256: String
    /// A `ClusterGenerationMode` raw value.
    public var generationMode: String
    public var prefillSchedule: String
    public var stages: [Stage]
    /// The pinned known-hosts file still has the pinned digest; nil when it could not be read.
    public var knownHostsPinMatches: Bool?
    public var identityFileUsable: Bool
    /// The worker binary matches its pin, and has the collective progress guard.
    public var workerVerified: Bool?
    public var progressGuard: Bool?
    public var workerDetail: String?
    /// Model files present with the manifest's sizes, of how many.
    public var filesPresent: Int?
    public var filesExpected: Int?
    /// What each Mac holds, as the plan tool says; nil when not read.
    public var holdings: String?
    /// The follower is reached over the link control channel (a setup made by
    /// the guided flow after pairing), not over SSH; nil when not known.
    public var overLink: Bool? = nil

    public var isLeader: Bool { role == ClusterConfiguration.Role.leader.rawValue }
}

/// The S00 orphan-wired guard's reading: the worker refuses to start while
/// more memory is wired than this Mac holds wired when idle and no Darkbloom
/// process runs.
public struct ClusterSetupMemoryGuard: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case clear, refused, skipped }
    public var decision: Decision
    public var wiredBytes: Int?
    public var baselineBytes: Int?
    public var detail: String?

    public init(decision: Decision, wiredBytes: Int?, baselineBytes: Int?, detail: String?) {
        self.decision = decision; self.wiredBytes = wiredBytes; self.baselineBytes = baselineBytes; self.detail = detail
    }
}

/// One model folder, as its manifest names it.
public struct ClusterSetupLocalModel: Codable, Sendable, Equatable {
    /// The folder's name, beside the setup's model directory.
    public var folder: String
    public var modelID: String
    public var version: String
    /// The manifest's aggregate digest: the artifact's identity.
    public var artifactSHA256: String
    public var totalBytes: Int64
    /// The manifest's files digest (`ClusterCatalogArtifact.filesDigest`: names, sizes and digests), which binds the
    /// file names the aggregate digest does not cover; nil from a build that does not report it.
    public var filesSHA256: String?

    public init(folder: String, modelID: String, version: String, artifactSHA256: String, totalBytes: Int64, filesSHA256: String? = nil) {
        self.folder = folder; self.modelID = modelID; self.version = version
        self.artifactSHA256 = artifactSHA256; self.totalBytes = totalBytes; self.filesSHA256 = filesSHA256
    }

    /// The same catalog entry: model ID, version and aggregate digest. Two entries can share every file and so the
    /// digest (the catalog's gemma-4-26b and gemma-4-26b-8bit); the runtime tells them apart by the manifest. When both
    /// sides report their files digest, the file names must match too (a folder of renamed files is another thing).
    public func sameEntry(_ other: ClusterSetupLocalModel) -> Bool {
        artifactSHA256 == other.artifactSHA256 && modelID == other.modelID && version == other.version
            && (filesSHA256 == nil || other.filesSHA256 == nil || filesSHA256 == other.filesSHA256)
    }
}

/// The pairings this Mac stored in the ceremony over the link (S17), by
/// public values only: shortened pins, the other Mac's attested name, the
/// roster label and generation. `error` says why the store could not be read.
public struct ClusterSetupLinkPairings: Codable, Sendable, Equatable {
    public struct Pairing: Codable, Sendable, Equatable {
        public var peerPin: String
        public var peerName: String
        public var clusterID: String
        public var generation: UInt64
        public var pairedAt: String

        public init(peerPin: String, peerName: String, clusterID: String, generation: UInt64, pairedAt: String) {
            self.peerPin = peerPin; self.peerName = peerName; self.clusterID = clusterID; self.generation = generation
            self.pairedAt = pairedAt
        }
    }
    public var localPin: String
    public var pairings: [Pairing]
    public var error: String?

    public init(localPin: String, pairings: [Pairing], error: String? = nil) {
        self.localPin = localPin; self.pairings = pairings; self.error = error
    }
}

/// A short code both screens show, so the person at the two Macs can tell
/// that the Mac which answered over the cable is the one in front of them.
public struct ClusterSetupPairingCode: Codable, Sendable, Equatable {
    public enum Basis: String, Codable, Sendable {
        /// The leader: the host key its setup pins, which the SSH connection just proved the other Mac holds.
        case pinnedHostKey
        /// The follower: its own SSH host key, read from its own SSH server.
        case ownHostKey
    }
    /// Six digits.
    public var code: String
    public var basis: Basis
    /// The key's algorithm, such as `ssh-ed25519`.
    public var algorithm: String
    /// This Mac's own key differs from the one its setup pins for it: someone pinned another key.
    public var differsFromPin: Bool

    public init(code: String, basis: Basis, algorithm: String, differsFromPin: Bool = false) {
        self.code = code; self.basis = basis; self.algorithm = algorithm; self.differsFromPin = differsFromPin
    }

    /// "482 913".
    public var spaced: String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }
}

/// One of the doctor's checks.
public struct ClusterSetupCheck: Codable, Sendable, Equatable {
    public var name: String
    /// A `ClusterDiagnosticsReport.Outcome` raw value.
    public var outcome: String
    public var detail: String

    public init(name: String, outcome: String, detail: String) {
        self.name = name; self.outcome = outcome; self.detail = detail
    }
}
