import Darwin
import Foundation
import SandboxCore

struct SandboxGenerationHighWatermark: Codable, Equatable {
    let sandboxID: SandboxID
    var generation: SandboxGeneration
}

struct SandboxCapacityState: Codable, Equatable {
    static let schemaVersion: UInt16 = 3
    static let maximumGenerationHighWatermarks = 4_096

    let schemaVersion: UInt16
    var mode: SandboxHostMode
    var nextFencingToken: UInt64
    var leases: [SandboxCapacityLease]
    var generationHighWatermarks: [SandboxGenerationHighWatermark]
    let storageIdentity: SandboxStorageVolumeIdentity

    init(
        schemaVersion: UInt16 = Self.schemaVersion,
        mode: SandboxHostMode,
        nextFencingToken: UInt64,
        leases: [SandboxCapacityLease],
        generationHighWatermarks: [SandboxGenerationHighWatermark] = [],
        storageIdentity: SandboxStorageVolumeIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.nextFencingToken = nextFencingToken
        self.leases = leases
        self.generationHighWatermarks = generationHighWatermarks
        self.storageIdentity = storageIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard storedSchemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sandbox capacity state version"
            )
        }
        mode = try container.decode(SandboxHostMode.self, forKey: .mode)
        nextFencingToken = try container.decode(
            UInt64.self,
            forKey: .nextFencingToken
        )
        leases = try container.decode(
            [SandboxCapacityLease].self,
            forKey: .leases
        )
        schemaVersion = Self.schemaVersion
        generationHighWatermarks = try container.decode(
            [SandboxGenerationHighWatermark].self,
            forKey: .generationHighWatermarks
        )
        storageIdentity = try container.decode(
            SandboxStorageVolumeIdentity.self,
            forKey: .storageIdentity
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode)
        try container.encode(nextFencingToken, forKey: .nextFencingToken)
        try container.encode(leases, forKey: .leases)
        try container.encode(
            generationHighWatermarks.sorted {
                $0.sandboxID.description < $1.sandboxID.description
            },
            forKey: .generationHighWatermarks
        )
        try container.encode(storageIdentity, forKey: .storageIdentity)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mode
        case nextFencingToken
        case leases
        case generationHighWatermarks
        case storageIdentity
    }
}

struct SandboxCapacityStateStore: Sendable {
    private static let stateFileName = "capacity.json"
    private static let maximumStateBytes = 1_048_576
    private static let leaseOperationLockSlotCount: UInt64 = 64

    private let stateDirectory: URL
    private let storageIdentity: SandboxStorageVolumeIdentity
    private let directorySynchronizationError:
        @Sendable (Int32) -> Int32?

    init(
        stateDirectory: URL,
        storageIdentity: SandboxStorageVolumeIdentity
    ) throws {
        try self.init(
            stateDirectory: stateDirectory,
            storageIdentity: storageIdentity,
            directorySynchronizationError: { descriptor in
                Self.systemSynchronizationError(descriptor)
            }
        )
    }

    init(
        stateDirectory: URL,
        storageIdentity: SandboxStorageVolumeIdentity,
        directorySynchronizationError:
            @escaping @Sendable (Int32) -> Int32?
    ) throws {
        guard stateDirectory.isFileURL,
              stateDirectory.baseURL == nil,
              stateDirectory.path.hasPrefix("/")
        else {
            throw SandboxCapacityError.unsafeStatePath
        }
        self.stateDirectory = stateDirectory.standardizedFileURL
        self.storageIdentity = storageIdentity
        self.directorySynchronizationError = directorySynchronizationError
    }

    func initialize(_ initial: SandboxCapacityState) throws -> SandboxCapacityState {
        try withLockedDirectory { directoryDescriptor in
            do {
                return try readState(from: directoryDescriptor)
            } catch SandboxCapacityError.uninitialized {
                try writeState(initial, to: directoryDescriptor)
                return initial
            }
        }
    }

    func validateExistingStateIfPresent() throws {
        do {
            _ = try read()
        } catch SandboxCapacityError.uninitialized {
            return
        }
    }

    func read() throws -> SandboxCapacityState {
        try withLockedDirectory { directoryDescriptor in
            try readState(from: directoryDescriptor)
        }
    }

    func acquireLeaseOperationLock(
        sandboxID: SandboxID,
        wait: Bool = true
    ) throws -> SandboxLeaseOperationLock {
        try acquireLeaseOperationLock(
            named: Self.leaseOperationLockName(for: sandboxID),
            wait: wait
        )
    }

    func acquireAllLeaseOperationLocks() throws
        -> [SandboxLeaseOperationLock]
    {
        var locks: [SandboxLeaseOperationLock] = []
        locks.reserveCapacity(Int(Self.leaseOperationLockSlotCount))
        for slot in 0..<Self.leaseOperationLockSlotCount {
            locks.append(
                try acquireLeaseOperationLock(
                    named: "lease-slot-\(slot).lock",
                    wait: true
                )
            )
        }
        return locks
    }

    private func acquireLeaseOperationLock(
        named lockName: String,
        wait: Bool
    ) throws -> SandboxLeaseOperationLock {
        let directoryDescriptor = try openStateDirectory()
        defer { close(directoryDescriptor) }
        let openedLock = try Self.openLockFile(
            named: lockName,
            in: directoryDescriptor
        )
        let lockDescriptor = openedLock.descriptor
        do {
            let lockOperation = wait ? LOCK_EX : LOCK_EX | LOCK_NB
            while flock(lockDescriptor, lockOperation) != 0 {
                let code = errno
                if !wait && (code == EWOULDBLOCK || code == EAGAIN) {
                    throw SandboxCapacityError.leaseOperationInProgress
                }
                guard code == EINTR else {
                    throw SandboxCapacityError.io(code)
                }
            }
            if openedLock.created {
                try Self.synchronizeFileDescriptor(lockDescriptor)
                if let code = Self.systemSynchronizationError(
                    directoryDescriptor
                ) {
                    throw SandboxCapacityError.publicationUncertain(code)
                }
            }
            try Self.requireLockBinding(
                descriptor: lockDescriptor,
                named: lockName,
                in: directoryDescriptor
            )
            return SandboxLeaseOperationLock(descriptor: lockDescriptor)
        } catch {
            close(lockDescriptor)
            throw error
        }
    }

    package static func leaseOperationLockName(
        for sandboxID: SandboxID
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in sandboxID.description.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "lease-slot-\(hash % leaseOperationLockSlotCount).lock"
    }

    func update<T>(
        _ operation: (inout SandboxCapacityState) throws -> T
    ) throws -> T {
        try withLockedDirectory { directoryDescriptor in
            var state = try readState(from: directoryDescriptor)
            let original = state
            let result = try operation(&state)
            try validate(state)
            if state != original {
                try writeState(state, to: directoryDescriptor)
            }
            return result
        }
    }

    private func withLockedDirectory<T>(
        _ operation: (Int32) throws -> T
    ) throws -> T {
        let directoryDescriptor = try openStateDirectory()
        defer { close(directoryDescriptor) }

        while flock(directoryDescriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw SandboxCapacityError.io(errno)
            }
        }
        defer { flock(directoryDescriptor, LOCK_UN) }
        return try operation(directoryDescriptor)
    }

    private func openStateDirectory() throws -> Int32 {
        do {
            return try SandboxAuthorityFileSystem.openPrivateDirectory(
                at: stateDirectory,
                createIfMissing: true
            )
        } catch {
            throw Self.authorityError(error)
        }
    }

    private func readState(from directoryDescriptor: Int32) throws
        -> SandboxCapacityState
    {
        let descriptor = openat(
            directoryDescriptor,
            Self.stateFileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                throw SandboxCapacityError.uninitialized
            }
            throw Self.pathError(code)
        }
        defer { close(descriptor) }
        let data: Data
        do {
            data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: Self.maximumStateBytes
            )
        } catch {
            throw Self.authorityError(error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state: SandboxCapacityState
        do {
            state = try decoder.decode(SandboxCapacityState.self, from: data)
        } catch {
            throw SandboxCapacityError.corruptState
        }
        try validate(state)
        return state
    }

    private func writeState(
        _ state: SandboxCapacityState,
        to directoryDescriptor: Int32
    ) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw SandboxCapacityError.corruptState
        }

        let temporaryName = ".capacity.\(UUID().uuidString).partial"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SandboxCapacityError.io(errno)
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try Self.validateFileDescriptor(descriptor)
        try Self.writeAll(data, to: descriptor)
        try Self.synchronizeFileDescriptor(descriptor)
        try Self.validateFileDescriptor(descriptor)
        let stagedMetadata = try Self.fileMetadata(descriptor)
        var pathMetadata = stat()
        guard fstatat(
            directoryDescriptor,
            temporaryName,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            SandboxAuthorityFileSystem.sameIdentity(
                stagedMetadata,
                pathMetadata
            )
        else {
            throw SandboxCapacityError.unsafeStatePath
        }
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            Self.stateFileName
        ) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
        shouldRemove = false
        let committedDescriptor = openat(
            directoryDescriptor,
            Self.stateFileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard committedDescriptor >= 0 else {
            throw SandboxCapacityError.publicationUncertain(errno)
        }
        defer { close(committedDescriptor) }
        do {
            try Self.validateFileDescriptor(committedDescriptor)
            let committedMetadata = try Self.fileMetadata(committedDescriptor)
            guard SandboxAuthorityFileSystem.sameIdentity(
                stagedMetadata,
                committedMetadata
            ) else {
                throw SandboxCapacityError.unsafeStatePath
            }
            let committedData =
                try SandboxAuthorityFileSystem.readStablePrivateFile(
                    committedDescriptor,
                    maximumBytes: Self.maximumStateBytes
                )
            guard committedData == data else {
                throw SandboxCapacityError.unsafeStatePath
            }
            do {
                try SandboxAuthorityFileSystem.synchronize(
                    committedDescriptor
                )
            } catch {
                let mapped = Self.authorityError(error)
                guard case .io(let code) = mapped else {
                    throw mapped
                }
                throw SandboxCapacityError.publicationUncertain(code)
            }
        } catch let error as SandboxCapacityError {
            throw error
        } catch {
            throw Self.authorityError(error)
        }
        if let synchronizationError =
            directorySynchronizationError(directoryDescriptor)
        {
            throw SandboxCapacityError.publicationUncertain(
                synchronizationError
            )
        }
    }

    private static func validate(_ state: SandboxCapacityState) throws {
        guard state.schemaVersion == SandboxCapacityState.schemaVersion,
              state.nextFencingToken > 0,
              state.leases.count <= SandboxCapacityPolicy.supportedRunningSandboxes,
              state.mode != .inference || state.leases.isEmpty
        else {
            throw SandboxCapacityError.corruptState
        }

        let sandboxIDs = state.leases.map(\.scope.sandboxID)
        let names = state.leases.map(\.virtualMachineName)
        let tokens = state.leases.map(\.scope.fencingToken.rawValue)
        let generationSandboxIDs = state.generationHighWatermarks.map(
            \.sandboxID
        )
        guard Set(sandboxIDs).count == sandboxIDs.count,
              Set(names).count == names.count,
              Set(tokens).count == tokens.count,
              state.generationHighWatermarks.count
                  <= SandboxCapacityState.maximumGenerationHighWatermarks,
              Set(generationSandboxIDs).count == generationSandboxIDs.count,
              state.leases.allSatisfy(Self.validate),
              (tokens.max() ?? 0) < state.nextFencingToken
        else {
            throw SandboxCapacityError.corruptState
        }
        let generations = Dictionary(
            uniqueKeysWithValues: state.generationHighWatermarks.map {
                ($0.sandboxID, $0.generation)
            }
        )
        guard state.leases.allSatisfy({
            generations[$0.scope.sandboxID] == $0.scope.generation
        }) else {
            throw SandboxCapacityError.corruptState
        }
    }

    private func validate(_ state: SandboxCapacityState) throws {
        try Self.validate(state)
        guard state.storageIdentity == storageIdentity else {
            throw SandboxCapacityError.storageIdentityMismatch
        }
    }

    private static func validate(_ lease: SandboxCapacityLease) -> Bool {
        let issued = lease.issuedAt.timeIntervalSinceReferenceDate
        let expires = lease.expiresAt.timeIntervalSinceReferenceDate
        let duration = lease.expiresAt.timeIntervalSince(lease.issuedAt)
        let expectedGrowth = try? SandboxStorageReservation.growthBytes(
            bootDiskBytes: lease.bootDiskBytes,
            workspaceBytes: lease.workspaceBytes
        )
        return SandboxVirtualMachineNamePolicy.isValid(lease.virtualMachineName)
            && lease.cpuCount > 0
            && lease.memoryBytes > 0
            && SandboxResourcePolicy.alpha.workspaceBytes.contains(
                lease.workspaceBytes
            )
            && SandboxDiskPolicy.alpha.bootDiskBytes.contains(
                lease.bootDiskBytes
            )
            && lease.reservedGrowthBytes == expectedGrowth
            && issued.isFinite
            && expires.isFinite
            && duration > 0
    }

    private static func openLockFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> (descriptor: Int32, created: Bool) {
        var created = false
        var descriptor = openat(
            directoryDescriptor,
            name,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(
                directoryDescriptor,
                name,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw pathError(errno)
        }
        do {
            try validateFileDescriptor(descriptor)
            return (descriptor, created)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func requireLockBinding(
        descriptor: Int32,
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        try validateFileDescriptor(descriptor)
        let lockedMetadata = try fileMetadata(descriptor)
        let rebound = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rebound >= 0 else {
            throw pathError(errno)
        }
        defer { close(rebound) }
        try validateFileDescriptor(rebound)
        let reboundMetadata = try fileMetadata(rebound)
        guard SandboxAuthorityFileSystem.sameIdentity(
            lockedMetadata,
            reboundMetadata
        ) else {
            throw SandboxCapacityError.unsafeStatePath
        }
    }

    private static func validateFileDescriptor(_ descriptor: Int32) throws {
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor
            )
        } catch {
            throw authorityError(error)
        }
    }

    private static func fileMetadata(_ descriptor: Int32) throws -> stat {
        do {
            return try SandboxAuthorityFileSystem.fileMetadata(descriptor)
        } catch {
            throw authorityError(error)
        }
    }

    private static func synchronizeFileDescriptor(
        _ descriptor: Int32
    ) throws {
        do {
            try SandboxAuthorityFileSystem.synchronize(descriptor)
        } catch {
            throw authorityError(error)
        }
    }

    private static func pathError(_ code: Int32) -> SandboxCapacityError {
        switch code {
        case ELOOP, ENOTDIR:
            return .unsafeStatePath
        default:
            return .io(code)
        }
    }

    private static func systemSynchronizationError(
        _ descriptor: Int32
    ) -> Int32? {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                return errno
            }
        }
        return nil
    }

    private static func authorityError(_ error: Error) -> SandboxCapacityError {
        guard let error = error as? SandboxAuthorityFileSystemError else {
            return .io(EIO)
        }
        switch error {
        case .unsafePath:
            return .unsafeStatePath
        case .publicationUncertain(let code):
            return .publicationUncertain(code)
        case .io(let code):
            return pathError(code)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SandboxCapacityError.io(errno)
                }
                guard count > 0 else {
                    throw SandboxCapacityError.io(EIO)
                }
                offset += count
            }
        }
    }
}

final class SandboxLeaseOperationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
