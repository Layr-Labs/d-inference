import Foundation
import SandboxCore
import SandboxRuntime

enum LumeVirtualMachineStartIntent {
    static let fileName = ".darkbloom-start-intent.json"

    static let schemaVersion: UInt16 = 2
    static let lifecycleControl = "broker_eof_v1"
    private static let maximumBytes = 16 * 1_024

    struct Intent: Equatable, Sendable {
        let intentID: UUID
        let installationID: UUID
        let owner: LumeVirtualMachineOwnership.Owner
        let initiatingFencingToken: SandboxFencingToken?

        fileprivate let record: Record

        fileprivate init(
            record: Record,
            owner: LumeVirtualMachineOwnership.Owner
        ) {
            intentID = record.intentID
            installationID = record.installationID
            self.owner = owner
            initiatingFencingToken = record.initiatingFencingToken
            self.record = record
        }
    }

    enum Presence: Equatable, Sendable {
        case absent
        case unresolved(Intent)
    }

    enum StopPlan: Equatable, Sendable {
        case proceed
        case clearAfterStopped(Intent)
    }

    static func persist(
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        initiatingScope: SandboxOperationScope?,
        in storageDirectory: URL
    ) throws -> Intent {
        let record = try Record(
            name: name,
            ownership: ownership,
            owner: owner,
            initiatingScope: initiatingScope
        )
        try requireCurrentOwnership(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
        let data = try encode(record, name: name)
        if let existing = try LumeVirtualMachineStartIntentAuthority
            .readIfPresent(
                name: name,
                fileName: fileName,
                maximumBytes: maximumBytes,
                in: storageDirectory
            )
        {
            _ = try decodeAndRequireMatch(
                existing,
                name: name,
                ownership: ownership,
                owner: owner
            )
            throw unresolvedFailure(name)
        }
        do {
            try LumeVirtualMachineStartIntentAuthority.publish(
                data,
                name: name,
                fileName: fileName,
                maximumBytes: maximumBytes,
                in: storageDirectory
            )
        } catch is LumeVirtualMachineStartIntentAuthority.PublicationConflict {
            guard let existing =
                try LumeVirtualMachineStartIntentAuthority.readIfPresent(
                    name: name,
                    fileName: fileName,
                    maximumBytes: maximumBytes,
                    in: storageDirectory
                )
            else {
                throw authorityFailure(
                    name,
                    detail: "start intent path disappeared"
                )
            }
            _ = try decodeAndRequireMatch(
                existing,
                name: name,
                ownership: ownership,
                owner: owner
            )
            throw unresolvedFailure(name)
        }
        try requireCurrentOwnership(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
        return Intent(record: record, owner: owner)
    }

    static func presence(
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        in storageDirectory: URL
    ) throws -> Presence {
        try requireCurrentOwnership(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
        guard let data =
            try LumeVirtualMachineStartIntentAuthority.readIfPresent(
                name: name,
                fileName: fileName,
                maximumBytes: maximumBytes,
                in: storageDirectory
            )
        else {
            return .absent
        }
        let record = try decodeAndRequireMatch(
            data,
            name: name,
            ownership: ownership,
            owner: owner
        )
        return .unresolved(Intent(record: record, owner: owner))
    }

    static func requireAbsent(
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        in storageDirectory: URL
    ) throws {
        guard case .absent = try presence(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        ) else {
            throw unresolvedFailure(name)
        }
    }

    static func resolveAfterRunningObserved(
        _ presence: Presence,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        observedState: SandboxVirtualMachineState,
        in storageDirectory: URL
    ) throws {
        guard observedState == .running else {
            throw authorityFailure(
                name,
                detail: "cannot resolve start intent without running proof"
            )
        }
        guard case .unresolved(let intent) = presence else {
            return
        }
        try clear(
            intent,
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
    }

    static func clearAfterSpawnFailure(
        _ intent: Intent,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        in storageDirectory: URL
    ) throws {
        try clear(
            intent,
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
    }

    static func clearAfterFailedStart(
        _ intent: Intent,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        terminalState: SandboxVirtualMachineState?,
        in storageDirectory: URL
    ) throws {
        guard intent.installationID == ownership.installationID,
              intent.owner == owner
        else {
            throw mismatchFailure(name)
        }
        guard terminalState == nil || terminalState == .stopped else {
            throw authorityFailure(
                name,
                detail: "failed start has not reached a terminal state"
            )
        }
        if terminalState == nil,
           case .absent = try LumeVirtualMachineOwnership.presence(
               name: name,
               owner: owner,
               in: storageDirectory
           )
        {
            return
        }
        try clear(
            intent,
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
    }

    static func prepareForStop(
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        observedState: SandboxVirtualMachineState,
        locallyTerminatedIntent: Intent?,
        in storageDirectory: URL
    ) throws -> StopPlan {
        let currentPresence = try presence(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
        guard case .unresolved(let intent) = currentPresence else {
            return .proceed
        }

        if observedState == .running {
            try resolveAfterRunningObserved(
                currentPresence,
                name: name,
                ownership: ownership,
                owner: owner,
                observedState: observedState,
                in: storageDirectory
            )
            return .proceed
        }
        if observedState == .stopped {
            // This schema records the pre-spawn EOF capability contract. Once
            // its broker is gone, a child still in the spawn-before-lock
            // window observes sticky EOF and cannot publish or start later.
            // A current stopped observation is terminal proof for this intent.
            return .clearAfterStopped(intent)
        }
        if locallyTerminatedIntent == intent {
            return .clearAfterStopped(intent)
        }
        if observedState == .starting {
            return .clearAfterStopped(intent)
        }
        throw unresolvedFailure(name)
    }

    static func completeStop(
        _ plan: StopPlan,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        observedState: SandboxVirtualMachineState,
        in storageDirectory: URL
    ) throws {
        guard observedState == .stopped else {
            throw authorityFailure(
                name,
                detail: "cannot resolve start intent before stop is proven"
            )
        }
        guard case .clearAfterStopped(let intent) = plan else {
            return
        }
        try clear(
            intent,
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
    }

    private static func clear(
        _ intent: Intent,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        in storageDirectory: URL
    ) throws {
        guard intent.installationID == ownership.installationID,
              intent.owner == owner
        else {
            throw mismatchFailure(name)
        }
        try requireCurrentOwnership(
            name: name,
            ownership: ownership,
            owner: owner,
            in: storageDirectory
        )
        guard let data =
            try LumeVirtualMachineStartIntentAuthority.readIfPresent(
                name: name,
                fileName: fileName,
                maximumBytes: maximumBytes,
                in: storageDirectory
            )
        else {
            throw authorityFailure(
                name,
                detail: "start intent is unavailable"
            )
        }
        let record = try decodeAndRequireMatch(
            data,
            name: name,
            ownership: ownership,
            owner: owner
        )
        guard record == intent.record,
              record.matches(
                  name: name,
                  ownership: ownership,
                  owner: owner
              )
        else {
            throw mismatchFailure(name)
        }
        try LumeVirtualMachineStartIntentAuthority.remove(
            expectedData: data,
            name: name,
            fileName: fileName,
            maximumBytes: maximumBytes,
            in: storageDirectory
        )
    }

    private static func requireCurrentOwnership(
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner,
        in storageDirectory: URL
    ) throws {
        let current = try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            owner: owner,
            in: storageDirectory
        )
        guard current == ownership else {
            throw mismatchFailure(name)
        }
    }

    private static func encode(
        _ record: Record,
        name: String
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(record)
            guard !data.isEmpty, data.count <= maximumBytes else {
                throw SandboxAuthorityFileSystemError.unsafePath
            }
            return data
        } catch {
            throw authorityFailure(
                name,
                detail: "could not encode start intent"
            )
        }
    }

    private static func decode(
        _ data: Data,
        name: String
    ) throws -> Record {
        let decoder = JSONDecoder()
        let version: VersionRecord
        do {
            version = try decoder.decode(VersionRecord.self, from: data)
        } catch {
            throw malformedFailure(name)
        }
        guard version.schemaVersion == schemaVersion else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) start intent has an unsupported version"
            )
        }
        let record: Record
        do {
            record = try decoder.decode(Record.self, from: data)
        } catch {
            throw malformedFailure(name)
        }
        guard record.isValid else {
            throw malformedFailure(name)
        }
        return record
    }

    private static func decodeAndRequireMatch(
        _ data: Data,
        name: String,
        ownership: LumeVirtualMachineOwnership.Identity,
        owner: LumeVirtualMachineOwnership.Owner
    ) throws -> Record {
        let record = try decode(data, name: name)
        guard record.matches(
            name: name,
            ownership: ownership,
            owner: owner
        ) else {
            throw mismatchFailure(name)
        }
        return record
    }

    private static func authorityFailure(
        _ name: String,
        detail: String
    ) -> SandboxRuntimeError {
        .unsupported("VM \(name) \(detail)")
    }

    private static func malformedFailure(
        _ name: String
    ) -> SandboxRuntimeError {
        .unsupported("VM \(name) start intent is malformed")
    }

    private static func mismatchFailure(
        _ name: String
    ) -> SandboxRuntimeError {
        .unsupported(
            "VM \(name) start intent does not match current ownership"
        )
    }

    private static func unresolvedFailure(
        _ name: String
    ) -> SandboxRuntimeError {
        .unsupported("VM \(name) has an unresolved start intent")
    }

    private struct VersionRecord: Decodable {
        let schemaVersion: UInt16
    }
}
