import Darwin
import Foundation

// Durable cluster incident log (PROD-PLAN S24).
//
// Ported from the design of the owner's oMLX `omlx/cluster/incidents.py`
// (Apache-2.0, multi-contributor upstream code; see ACKNOWLEDGEMENTS): every
// abnormal end state of a cluster session becomes one durable, already
// redacted record in `~/.darkbloom/cluster/incidents.json`. Readers poll with
// a `since` cursor and merge; nothing a reader does can erase a record.
// Dismissal is the only removal path, and supersession ("launch #4 replaces
// #3") flags the earlier record but keeps it.
//
// Differences from oMLX, for Darkbloom: several processes write the same file
// (the serving provider, the follower member, the `cluster incidents`
// command), so every change re-reads the file under an advisory lock instead
// of trusting a per-process copy; every launch failure carries a classified
// `reason_code` (46 of the owner's 58 oMLX incidents were launch failures and
// all 58 were left `unknown_failure`); a record names the rank and model it is
// about. The file keeps oMLX's field names, so the owner's tools read it.

/// How bad an incident is.
public enum ClusterIncidentSeverity: String, Codable, Sendable, CaseIterable {
    case info, warn, error
}

/// One abnormal (or notable) cluster end state, already redacted.
public struct ClusterIncident: Codable, Sendable, Equatable {
    /// Store-assigned and strictly increasing: the cursor a reader sends back as `since`.
    public let seq: UInt64
    /// 32 lowercase hexadecimal characters.
    public let id: String
    /// Seconds since 1970, UTC.
    public let ts: Double
    public let severity: ClusterIncidentSeverity
    /// Who observed it: `leader`, `follower`, `owner`, `link`, `member`, `cli`.
    public let source: String
    /// The end state, a stable machine code (`ClusterIncidentStateCode`).
    public let stateCode: String
    /// Why, a stable machine code (`ClusterFailureReason`); every launch failure has one.
    public let reasonCode: String?
    /// The guidance a person can act on (`ClusterGuidance.code`).
    public let guidanceCode: String?
    /// Redacted and bounded; never a prompt, token, credential, address or home path.
    public let message: String
    /// The session (membership epoch) or launch attempt the incident belongs to.
    public let jobID: String?
    /// The cluster the incident belongs to.
    public let deploymentID: String?
    public let modelID: String?
    public let rank: Int?
    public let bundleRef: String?
    /// Where a mirrored record came from (`follower:<epoch>:<seq>`): a record
    /// with the same origin is never added twice.
    public let origin: String?
    public internal(set) var dismissedAt: Double?
    public internal(set) var supersededBy: String?

    enum CodingKeys: String, CodingKey {
        case seq, id, ts, severity, source, message, rank
        case stateCode = "state_code", reasonCode = "reason_code", guidanceCode = "guidance_code"
        case jobID = "job_id", deploymentID = "deployment_id", modelID = "model_id", bundleRef = "bundle_ref"
        case origin
        case dismissedAt = "dismissed_at", supersededBy = "superseded_by"
    }

    public var isDismissed: Bool { dismissedAt != nil }
}

/// Stable end-state codes. The first three are oMLX's own.
public enum ClusterIncidentStateCode: String, Codable, Sendable, CaseIterable {
    /// The pair could not be brought up: a launch failure, always with a reason.
    case activationLaunchFailed = "activation_launch_failed"
    /// A start was refused before anything was launched (configuration, policy, memory).
    case activationRejected = "activation_rejected"
    /// A topology change or start was refused while a request was being served.
    case activationModelBusy = "activation_model_busy"
    /// A serving session ended without being asked to (rank lost, guard, lease).
    case sessionFailed = "session_failed"
    /// A rank's process ended while the session was serving.
    case peerLost = "peer_lost"
    /// A stop could not prove every owner released its device.
    case cleanupUnresolved = "cleanup_unresolved"
    /// The link control edge to the other member went down.
    case linkEdgeDown = "link_edge_down"
    /// The other member's mirrored status stopped arriving.
    case followerStatusStale = "follower_status_stale"
    /// The other member reported itself failed.
    case followerFailed = "follower_failed"
    /// A member could not serve a start the coordinator committed.
    case memberStartFailed = "member_start_failed"
}

/// What a caller supplies; the store adds the sequence, identifier and time.
public struct ClusterIncidentDraft: Sendable, Equatable {
    public var severity: ClusterIncidentSeverity
    public var source: String
    public var stateCode: String
    public var reasonCode: String?
    public var guidanceCode: String?
    public var message: String
    public var jobID: String?
    public var deploymentID: String?
    public var modelID: String?
    public var rank: Int?
    public var origin: String?

    public init(severity: ClusterIncidentSeverity, source: String, stateCode: ClusterIncidentStateCode,
                reason: ClusterFailureReason? = nil, guidanceCode: String? = nil, message: String,
                jobID: String? = nil, deploymentID: String? = nil, modelID: String? = nil, rank: Int? = nil,
                origin: String? = nil) {
        self.init(severity: severity, source: source, stateCode: stateCode.rawValue, reasonCode: reason?.rawValue,
                  guidanceCode: guidanceCode ?? reason.map { ClusterGuidance.guidance(for: $0).code }, message: message,
                  jobID: jobID, deploymentID: deploymentID, modelID: modelID, rank: rank, origin: origin)
    }

    /// Raw codes, for a record mirrored from another Mac whose codes this build may not know.
    public init(severity: ClusterIncidentSeverity, source: String, stateCode: String, reasonCode: String?,
                guidanceCode: String?, message: String, jobID: String? = nil, deploymentID: String? = nil,
                modelID: String? = nil, rank: Int? = nil, origin: String? = nil) {
        self.severity = severity; self.source = source; self.stateCode = stateCode; self.reasonCode = reasonCode
        self.guidanceCode = guidanceCode; self.message = message; self.jobID = jobID; self.deploymentID = deploymentID
        self.modelID = modelID; self.rank = rank; self.origin = origin
    }

    /// A classified failure: reason and guidance come from `explanation`.
    public init(severity: ClusterIncidentSeverity = .error, source: String, stateCode: ClusterIncidentStateCode,
                explanation: ClusterFailureExplanation, jobID: String? = nil, deploymentID: String? = nil,
                modelID: String? = nil, rank: Int? = nil) {
        self.init(severity: severity, source: source, stateCode: stateCode, reason: explanation.reason,
                  guidanceCode: explanation.guidance.code, message: explanation.message, jobID: jobID,
                  deploymentID: deploymentID, modelID: modelID, rank: rank)
    }
}

/// What a reader gets: the records after its cursor, and the store's identity.
public struct ClusterIncidentFeed: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    /// Identity of this sequence numbering; a new one means the log was reset
    /// and a reader's cursor no longer means anything.
    public let epoch: String
    public let latestSeq: UInt64
    /// Set when the file could not be read; the feed is then empty, never an error.
    public let loadError: String?
    public let incidents: [ClusterIncident]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", epoch, latestSeq = "latest_seq", loadError = "load_error", incidents
    }

    /// Records not dismissed and not superseded, newest first.
    public var open: [ClusterIncident] {
        incidents.filter { $0.dismissedAt == nil && $0.supersededBy == nil }.reversed()
    }
}

public enum ClusterIncidentLogError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsafePath(String)
    case io(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .unsafePath(let detail): "incident log path is unsafe: \(detail)"
        case .io(let detail): "incident log I/O failed: \(detail)"
        case .invalid(let detail): "invalid incident: \(detail)"
        }
    }
}

/// Persisted FIFO ring of the last `maximumIncidents` incidents, shared by
/// every process of this user on this Mac. Thread-safe; every mutation is one
/// read-modify-write under an exclusive advisory lock on a sidecar file, then
/// an atomic rename of a 0600 file in a 0700 directory. A corrupt or missing
/// file never stops a caller: reads report it in `loadError` and return
/// nothing; the next record moves the corrupt file aside and starts a new
/// epoch.
public final class ClusterIncidentLog: @unchecked Sendable {
    public static let maximumIncidents = 200
    public static let maximumMessageBytes = 512
    static let maximumFileBytes = 2 * 1024 * 1024
    static let maximumFieldBytes = 128

    /// `~/.darkbloom/cluster/incidents.json` for this home directory.
    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/incidents.json")
    }

    public let file: URL
    private let lockFile: URL
    private let redact: @Sendable (String) -> String
    private let clock: @Sendable () -> Double
    private let lock = NSLock()

    /// `redact` runs over every message before it is stored (the provider
    /// passes its diagnostic redaction: addresses, host and user names, home
    /// paths, key material). It must never throw away the meaning of a message.
    public init(file: URL, redact: @escaping @Sendable (String) -> String = { $0 },
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.file = file
        lockFile = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".lock")
        self.redact = redact
        self.clock = clock
    }

    // MARK: Reading

    /// Never throws: a missing file is an empty feed with a fresh epoch, an
    /// unreadable one an empty feed that names the error.
    public func feed(since cursor: UInt64 = 0) -> ClusterIncidentFeed {
        lock.withLock {
            switch Self.load(file) {
            case .missing:
                return .init(schemaVersion: ClusterIncidentFeed.schemaVersion, epoch: "", latestSeq: 0,
                             loadError: nil, incidents: [])
            case .corrupt(let reason):
                return .init(schemaVersion: ClusterIncidentFeed.schemaVersion, epoch: "", latestSeq: 0,
                             loadError: reason, incidents: [])
            case .loaded(let stored):
                return .init(schemaVersion: ClusterIncidentFeed.schemaVersion, epoch: stored.epoch,
                             latestSeq: stored.incidents.last?.seq ?? 0, loadError: nil,
                             incidents: stored.incidents.filter { $0.seq > cursor })
            }
        }
    }

    // MARK: Writing

    /// Appends one incident. The message is redacted, stripped of control
    /// characters and bounded before it is stored.
    @discardableResult
    public func record(_ draft: ClusterIncidentDraft) throws -> ClusterIncident {
        try Self.requireField(draft.source, "source"); try Self.requireField(draft.stateCode, "state_code")
        for (value, name) in [(draft.reasonCode, "reason_code"), (draft.guidanceCode, "guidance_code"),
                              (draft.jobID, "job_id"), (draft.deploymentID, "deployment_id"), (draft.origin, "origin")] {
            if let value { try Self.requireField(value, name) }
        }
        let message = Self.bounded(redact(Self.printable(draft.message)), Self.maximumMessageBytes)
        let model = draft.modelID.map { Self.bounded(redact(Self.printable($0)), 256) }
        return try mutate { stored in
            if let origin = draft.origin, let existing = stored.incidents.first(where: { $0.origin == origin }) {
                return existing
            }
            let incident = ClusterIncident(seq: stored.nextSeq, id: Self.newID(), ts: clock(), severity: draft.severity,
                source: draft.source, stateCode: draft.stateCode, reasonCode: draft.reasonCode,
                guidanceCode: draft.guidanceCode, message: message, jobID: draft.jobID,
                deploymentID: draft.deploymentID, modelID: model, rank: draft.rank, bundleRef: nil,
                origin: draft.origin, dismissedAt: nil, supersededBy: nil)
            stored.incidents.append(incident)
            if stored.incidents.count > Self.maximumIncidents {
                stored.incidents.removeFirst(stored.incidents.count - Self.maximumIncidents)
            }
            stored.nextSeq += 1
            return incident
        }
    }

    /// Marks one incident dismissed (kept, flagged). False when no record has that ID.
    @discardableResult
    public func dismiss(id: String) throws -> Bool {
        try mutate { stored in
            guard let index = stored.incidents.firstIndex(where: { $0.id == id }) else { return false }
            if stored.incidents[index].dismissedAt == nil { stored.incidents[index].dismissedAt = clock() }
            return true
        }
    }

    /// Flags every open incident of `jobID` other than `incidentID` as superseded by it.
    @discardableResult
    public func supersede(jobID: String, by incidentID: String) throws -> Int {
        try mutate { stored in
            var changed = 0
            for index in stored.incidents.indices where stored.incidents[index].jobID == jobID
                && stored.incidents[index].id != incidentID && stored.incidents[index].supersededBy == nil {
                stored.incidents[index].supersededBy = incidentID; changed += 1
            }
            return changed
        }
    }

    // MARK: Storage

    struct Stored: Codable, Equatable {
        var schemaVersion: Int
        var epoch: String
        var nextSeq: UInt64
        var incidents: [ClusterIncident]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", epoch, nextSeq = "next_seq", incidents
        }
    }

    enum Loaded { case missing, corrupt(String), loaded(Stored) }

    static func load(_ file: URL) -> Loaded {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { return errno == ENOENT ? .missing : .corrupt("cannot open (errno \(errno))") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .corrupt("not a regular file") }
        guard info.st_size <= maximumFileBytes else { return .corrupt("larger than \(maximumFileBytes) bytes") }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size) else { return .corrupt("short read") }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: bytes)
            guard stored.schemaVersion == ClusterIncidentFeed.schemaVersion, !stored.epoch.isEmpty,
                  stored.incidents.count <= maximumIncidents,
                  zip(stored.incidents, stored.incidents.dropFirst()).allSatisfy({ $0.seq < $1.seq }),
                  stored.nextSeq > (stored.incidents.last?.seq ?? 0) else {
                return .corrupt("records out of order or schema differs")
            }
            return .loaded(stored)
        } catch {
            return .corrupt("not an incident log (\(String(describing: error).prefix(160)))")
        }
    }

    private func mutate<T>(_ change: (inout Stored) throws -> T) throws -> T {
        try lock.withLock {
            let directory = file.deletingLastPathComponent()
            try Self.makePrivateDirectory(directory)
            let lockDescriptor = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockDescriptor >= 0 else { throw ClusterIncidentLogError.io("lock file (errno \(errno))") }
            defer { close(lockDescriptor) }
            guard flock(lockDescriptor, LOCK_EX) == 0 else { throw ClusterIncidentLogError.io("lock (errno \(errno))") }
            defer { flock(lockDescriptor, LOCK_UN) }
            var stored: Stored
            switch Self.load(file) {
            case .missing:
                stored = .init(schemaVersion: ClusterIncidentFeed.schemaVersion, epoch: Self.newEpoch(), nextSeq: 1, incidents: [])
            case .corrupt:
                // Kept for whoever investigates, never trusted, never blocking.
                let aside = directory.appendingPathComponent("incidents.corrupt.json")
                _ = unlink(aside.path)
                _ = rename(file.path, aside.path)
                stored = .init(schemaVersion: ClusterIncidentFeed.schemaVersion, epoch: Self.newEpoch(), nextSeq: 1, incidents: [])
            case .loaded(let value):
                stored = value
            }
            let original = stored
            let result = try change(&stored)
            if stored != original { try Self.save(stored, to: file) }
            return result
        }
    }

    static func save(_ stored: Stored, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(stored)
        bytes.append(10)
        try writeAtomically(bytes, to: file)
    }

    /// Writes a 0600 temporary file next to `file`, syncs it and renames it over `file`.
    static func writeAtomically(_ bytes: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(file.lastPathComponent).\(newID().prefix(12)).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClusterIncidentLogError.io("temporary file (errno \(errno))") }
        var ok = false
        defer { if !ok { _ = unlink(temporary.path) } }
        let written = bytes.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return -1 }
                offset += count
            }
            return offset
        }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written == bytes.count, synced else { throw ClusterIncidentLogError.io("write (errno \(errno))") }
        guard rename(temporary.path, file.path) == 0 else { throw ClusterIncidentLogError.io("rename (errno \(errno))") }
        ok = true
    }

    /// Creates the directory (and `~/.darkbloom`) owner-only; refuses a symbolic link.
    static func makePrivateDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ClusterIncidentLogError.unsafePath("not a directory") }
            guard info.st_uid == getuid() else { throw ClusterIncidentLogError.unsafePath("owned by another user") }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ClusterIncidentLogError.io("create directory: \(error.localizedDescription)") }
    }

    static func requireField(_ value: String, _ name: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumFieldBytes,
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ClusterIncidentLogError.invalid("\(name) must be 1-\(maximumFieldBytes) printable ASCII characters")
        }
    }

    /// Control characters become spaces; runs of whitespace collapse.
    static func printable(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let space = scalar.value < 32 || scalar.value == 127 || scalar == " "
            if space { if !lastWasSpace && !result.isEmpty { result.append(" ") }; lastWasSpace = true; continue }
            result.unicodeScalars.append(scalar); lastWasSpace = false
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// At most `maximum` UTF-8 bytes, cut at a character boundary, with an ellipsis when cut.
    static func bounded(_ text: String, _ maximum: Int) -> String {
        guard text.utf8.count > maximum else { return text }
        var result = ""
        for character in text {
            if result.utf8.count + character.utf8.count > maximum - 3 { break }
            result.append(character)
        }
        return result + "..."
    }

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func newEpoch() -> String { String(newID().prefix(16)) }
}
