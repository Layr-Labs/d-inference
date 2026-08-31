import Foundation

/// Provider-reported release update lifecycle. Raw values are a frozen wire contract.
public enum UpdateLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case serving
    case drainingForUpdate = "draining_for_update"
    case installing
    case reconnecting
    case applicationVerifying = "application_verifying"
    case modelReloading = "model_reloading"
    case ready
    case blocked

    fileprivate var rank: Int? {
        switch self {
        case .serving: return 0
        case .drainingForUpdate: return 1
        case .installing: return 2
        case .reconnecting: return 3
        case .applicationVerifying: return 4
        case .modelReloading: return 5
        case .ready: return 6
        case .blocked: return nil
        }
    }
}

/// One model slot that must be restored after a release restart.
/// Empty strings are normalized to nil so optional wire fields are actually omitted.
public struct WarmIntent: Codable, Sendable, Equatable {
    public let modelId: String?
    public let modelHash: String?
    public let slotId: String?
    public let kvBackend: String?
    public let kvQuantization: String?
    public let mtpModelId: String?
    public let desiredGeneration: UInt64?

    public init(
        modelId: String? = nil,
        modelHash: String? = nil,
        slotId: String? = nil,
        kvBackend: String? = nil,
        kvQuantization: String? = nil,
        mtpModelId: String? = nil,
        desiredGeneration: UInt64? = nil
    ) {
        func nonempty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        self.modelId = nonempty(modelId)
        self.modelHash = nonempty(modelHash)
        self.slotId = nonempty(slotId)
        self.kvBackend = nonempty(kvBackend)
        self.kvQuantization = nonempty(kvQuantization)
        self.mtpModelId = nonempty(mtpModelId)
        self.desiredGeneration = desiredGeneration == 0 ? nil : desiredGeneration
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case modelHash = "model_hash"
        case slotId = "slot_id"
        case kvBackend = "kv_backend"
        case kvQuantization = "kv_quantization"
        case mtpModelId = "mtp_model_id"
        case desiredGeneration = "desired_generation"
    }
}

/// Exact coordinator-authorized artifact target. It intentionally contains no
/// provider, account, session, credential, or cohort data.
public struct AuthorizedReleaseUpdate: Codable, Sendable, Equatable {
    public let version: String
    public let platform: String
    public let backend: String?
    public let binaryHash: String
    public let bundleHash: String
    public let metallibHash: String?
    public let inferenceWorkerBinaryHash: String?
    public let url: String
    public let desiredGeneration: UInt64

    public init(
        version: String,
        platform: String,
        backend: String? = nil,
        binaryHash: String,
        bundleHash: String,
        metallibHash: String? = nil,
        inferenceWorkerBinaryHash: String? = nil,
        url: String,
        desiredGeneration: UInt64
    ) {
        self.version = version
        self.platform = platform
        self.backend = backend.flatMap { $0.isEmpty ? nil : $0 }
        self.binaryHash = binaryHash
        self.bundleHash = bundleHash
        self.metallibHash = metallibHash.flatMap { $0.isEmpty ? nil : $0 }
        self.inferenceWorkerBinaryHash =
            inferenceWorkerBinaryHash.flatMap { $0.isEmpty ? nil : $0 }
        self.url = url
        self.desiredGeneration = desiredGeneration
    }

    public var releaseInfo: ReleaseInfo {
        ReleaseInfo(
            version: version,
            platform: platform,
            url: url,
            bundleHash: bundleHash,
            binaryHash: binaryHash,
            metallibHash: metallibHash,
            inferenceWorkerBinaryHash: inferenceWorkerBinaryHash)
    }

    func hasSameArtifact(as other: AuthorizedReleaseUpdate) -> Bool {
        version == other.version &&
            platform == other.platform &&
            backend == other.backend &&
            binaryHash == other.binaryHash &&
            bundleHash == other.bundleHash &&
            metallibHash == other.metallibHash &&
            inferenceWorkerBinaryHash == other.inferenceWorkerBinaryHash &&
            url == other.url
    }
    enum CodingKeys: String, CodingKey {
        case version, platform, backend, url
        case binaryHash = "binary_hash"
        case bundleHash = "bundle_hash"


        case metallibHash = "metallib_hash"
        case inferenceWorkerBinaryHash = "inference_worker_binary_hash"
        case desiredGeneration = "desired_generation"
    }
}

public struct UpdateLifecycleRecord: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var state: UpdateLifecycleState
    public var command: AuthorizedReleaseUpdate?
    public var warmIntents: [WarmIntent]

    public init(
        schema: Int = UpdateLifecycleRecord.currentSchema,
        state: UpdateLifecycleState = .serving,
        command: AuthorizedReleaseUpdate? = nil,
        warmIntents: [WarmIntent] = []
    ) {
        self.schema = schema
        self.state = state
        self.command = command
        self.warmIntents = warmIntents
    }

    /// The wire contract always carries the authorized generation, even when
    /// no model was warm or all model intents have finished restoring.
    public var reportedWarmIntent: WarmIntent? {
        if let first = warmIntents.first { return first }
        return command.map {
            WarmIntent(desiredGeneration: $0.desiredGeneration)
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, state, command
        case warmIntents = "warm_intents"
    }
}

public enum UpdateLifecycleError: Error, Sendable, Equatable, CustomStringConvertible {
    case warmIntentsRemaining

    case invalidGeneration
    case staleGeneration(current: UInt64, received: UInt64)
    case conflictingGeneration(UInt64)
    case invalidSemanticVersion(String)
    case downgrade(current: String, target: String)
    case invalidTransition(from: UpdateLifecycleState, to: UpdateLifecycleState)
    case blockedUntilNewerGeneration(UInt64)
    case corruptState

    public var description: String {
        switch self {
        case .invalidGeneration: return "desired update generation must be greater than zero"
        case .staleGeneration(let current, let received):
            return "stale update generation \(received); current generation is \(current)"
        case .conflictingGeneration(let generation):
            return "conflicting release for update generation \(generation)"
        case .invalidSemanticVersion(let version): return "invalid semantic version \(version)"
        case .downgrade(let current, let target):
            return "release downgrade refused: current=\(current) target=\(target)"
        case .invalidTransition(let from, let to):
            return "invalid update lifecycle transition \(from.rawValue) -> \(to.rawValue)"
        case .blockedUntilNewerGeneration:
            return "update is blocked until a strictly newer target is authorized"
        case .warmIntentsRemaining:
            return "update cannot become ready before every warm intent is restored"
        case .corruptState: return "update lifecycle state is corrupt"
        }

    }
}
public enum UpdateConnectionCertificationPolicy {
    public static func acceptsEvidence(
        evidenceGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        evidenceGeneration == currentGeneration
    }

    public static func canReportReady(
        restorationGeneration: UInt64,
        certifiedGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        restorationGeneration == currentGeneration &&
            certifiedGeneration == currentGeneration
    }
}

public struct DeferredDesiredModelsBuffer: Sendable, Equatable {
    public private(set) var entries: [CoordinatorMessage.DesiredModelEntry]?

    public init() {}

    public mutating func record(
        _ entries: [CoordinatorMessage.DesiredModelEntry]
    ) {
        self.entries = entries
    }

    public mutating func take() -> [CoordinatorMessage.DesiredModelEntry]? {
        defer { entries = nil }
        return entries
    }
}

/// Pure monotonic state machine used by the provider loop and focused tests.
public struct UpdateLifecycleReconciler: Sendable {
    public private(set) var record: UpdateLifecycleRecord

    public init(record: UpdateLifecycleRecord = UpdateLifecycleRecord()) throws {
        guard record.schema == UpdateLifecycleRecord.currentSchema else {
            throw UpdateLifecycleError.corruptState
        }
        self.record = record
    }

    /// Accept a coordinator-selected target. Generation is stable per artifact:
    /// equal identical commands are idempotent; stale, equal-conflicting, and
    /// higher-generation same-artifact commands are rejected. Only a strictly
    /// newer target may supersede terminal ready/blocked state.
    public mutating func authorize(
        _ command: AuthorizedReleaseUpdate,
        currentVersion: String,
        warmIntents: [WarmIntent]
    ) throws -> Bool {
        guard command.desiredGeneration > 0 else { throw UpdateLifecycleError.invalidGeneration }
        guard let current = SemanticVersion(currentVersion) else {
            throw UpdateLifecycleError.invalidSemanticVersion(currentVersion)
        }
        guard let target = SemanticVersion(command.version) else {
            throw UpdateLifecycleError.invalidSemanticVersion(command.version)
        }
        guard target >= current else {
            throw UpdateLifecycleError.downgrade(current: currentVersion, target: command.version)
        }

        if let existing = record.command {
            if command.desiredGeneration < existing.desiredGeneration {
                throw UpdateLifecycleError.staleGeneration(
                    current: existing.desiredGeneration,
                    received: command.desiredGeneration)
            }
            if command.desiredGeneration == existing.desiredGeneration {
                guard command == existing else {
                    throw UpdateLifecycleError.conflictingGeneration(command.desiredGeneration)
                }
                return false
            }
            guard !command.hasSameArtifact(as: existing) else {
                throw UpdateLifecycleError.conflictingGeneration(
                    command.desiredGeneration)
            }
            guard let existingTarget = SemanticVersion(existing.version),
                  target > existingTarget
            else {
                throw UpdateLifecycleError.conflictingGeneration(
                    command.desiredGeneration)
            }
            guard record.state == .blocked || record.state == .ready else {
                throw UpdateLifecycleError.invalidTransition(
                    from: record.state, to: .serving)
            }
            record = UpdateLifecycleRecord()
        }

        let ordered = warmIntents.sorted {
            ($0.slotId ?? $0.modelId ?? "", $0.modelId ?? "")
                < ($1.slotId ?? $1.modelId ?? "", $1.modelId ?? "")
        }.map {
            WarmIntent(
                modelId: $0.modelId,
                modelHash: $0.modelHash,
                slotId: $0.slotId,
                kvBackend: $0.kvBackend,
                kvQuantization: $0.kvQuantization,
                mtpModelId: $0.mtpModelId,
                desiredGeneration: command.desiredGeneration)
        }
        record.command = command
        record.warmIntents = ordered
        record.state = .serving
        return true
    }

    public mutating func transition(to next: UpdateLifecycleState) throws {
        guard let command = record.command else { throw UpdateLifecycleError.corruptState }
        if record.state == .blocked {
            throw UpdateLifecycleError.blockedUntilNewerGeneration(command.desiredGeneration)
        }
        guard next != .blocked else {
            record.state = .blocked
            return
        }
        guard let currentRank = record.state.rank, let nextRank = next.rank,
              nextRank == currentRank + 1
        else {
            throw UpdateLifecycleError.invalidTransition(from: record.state, to: next)
        }
        if next == .ready, !record.warmIntents.isEmpty {
            throw UpdateLifecycleError.warmIntentsRemaining
        }
        record.state = next
    }

    public mutating func completeNextWarmIntent(_ intent: WarmIntent) throws {
        guard record.state == .modelReloading,
              record.warmIntents.first == intent
        else {
            throw UpdateLifecycleError.corruptState
        }
        record.warmIntents.removeFirst()
    }

    public mutating func block() {
        guard record.command != nil else { return }
        record.state = .blocked
    }
}

public enum ManualUpdateDecision: Sendable, Equatable {
    case refuseLiveProvider
    case resumeCoordinatorAuthorization(AuthorizedReleaseUpdate)
    case noCoordinatorAuthorization
}

public enum ManualUpdatePolicy {
    public static func decide(
        providerRunning: Bool,
        record: UpdateLifecycleRecord
    ) -> ManualUpdateDecision {
        if providerRunning { return .refuseLiveProvider }
        guard let command = record.command else {
            return .noCoordinatorAuthorization
        }
        switch record.state {
        case .drainingForUpdate, .installing, .reconnecting,
             .applicationVerifying, .modelReloading:
            return .resumeCoordinatorAuthorization(command)
        case .serving, .ready, .blocked:
            return .noCoordinatorAuthorization
        }
    }
}

/// Crash-safe, mode-0600 persistence for non-secret update state.
public struct UpdateLifecycleStore: Sendable {
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DARKBLOOM_UPDATE_LIFECYCLE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/update-lifecycle.json")
    }

    public let file: URL

    public init(file: URL = UpdateLifecycleStore.path()) {
        self.file = file
    }

    public func load() throws -> UpdateLifecycleRecord {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return UpdateLifecycleRecord()
        }
        let data = try Data(contentsOf: file)
        let record = try JSONDecoder().decode(UpdateLifecycleRecord.self, from: data)
        guard record.schema == UpdateLifecycleRecord.currentSchema,
              Self.isValidPersistedRecord(record)
        else {
            throw UpdateLifecycleError.corruptState
        }
        return record
    }

    private static func isValidPersistedRecord(
        _ record: UpdateLifecycleRecord
    ) -> Bool {
        if record.state == .serving {
            return record.command == nil && record.warmIntents.isEmpty
        }
        guard let command = record.command,
              command.desiredGeneration > 0,
              SemanticVersion(command.version) != nil,
              let components = URLComponents(string: command.url),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              record.warmIntents.allSatisfy({
                  $0.desiredGeneration == command.desiredGeneration
              })
        else {
            return false
        }
        return record.state != .ready || record.warmIntents.isEmpty
    }


    public func save(_ record: UpdateLifecycleRecord) throws {
        guard record.schema == UpdateLifecycleRecord.currentSchema,
              Self.isValidPersistedRecord(record)
        else {
            throw UpdateLifecycleError.corruptState
        }
        try UpdateAtomicFilesystem.writeJSON(record, to: file)
    }
}
