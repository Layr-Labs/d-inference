import Darwin
import Foundation
import SandboxCore

struct SandboxCapacityState: Codable, Equatable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    var mode: SandboxHostMode
    var nextFencingToken: UInt64
    var leases: [SandboxCapacityLease]
}

struct SandboxCapacityStateStore: Sendable {
    private static let stateFileName = "capacity.json"
    private static let maximumStateBytes = 1_048_576

    private let stateDirectory: URL
    private let directorySynchronizationError:
        @Sendable (Int32) -> Int32?

    init(stateDirectory: URL) throws {
        try self.init(
            stateDirectory: stateDirectory,
            directorySynchronizationError: { descriptor in
                fsync(descriptor) == 0 ? nil : errno
            }
        )
    }

    init(
        stateDirectory: URL,
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

    func read() throws -> SandboxCapacityState {
        try withLockedDirectory { directoryDescriptor in
            try readState(from: directoryDescriptor)
        }
    }

    func acquireLeaseOperationLock(
        sandboxID: SandboxID,
        wait: Bool = true
    ) throws -> SandboxLeaseOperationLock {
        let directoryDescriptor = try openStateDirectory()
        defer { close(directoryDescriptor) }
        let lockName = "lease-\(sandboxID.description).lock"
        let lockDescriptor = try Self.openLockFile(
            named: lockName,
            in: directoryDescriptor
        )
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

    func update<T>(
        _ operation: (inout SandboxCapacityState) throws -> T
    ) throws -> T {
        try withLockedDirectory { directoryDescriptor in
            var state = try readState(from: directoryDescriptor)
            let original = state
            let result = try operation(&state)
            try Self.validate(state)
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
        try Self.validate(state)
        return state
    }

    private func writeState(
        _ state: SandboxCapacityState,
        to directoryDescriptor: Int32
    ) throws {
        try Self.validate(state)
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
        guard fsync(descriptor) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
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
            guard fsync(committedDescriptor) == 0 else {
                throw SandboxCapacityError.publicationUncertain(errno)
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
        guard Set(sandboxIDs).count == sandboxIDs.count,
              Set(names).count == names.count,
              Set(tokens).count == tokens.count,
              state.leases.allSatisfy(Self.validate),
              (tokens.max() ?? 0) < state.nextFencingToken
        else {
            throw SandboxCapacityError.corruptState
        }
    }

    private static func validate(_ lease: SandboxCapacityLease) -> Bool {
        let issued = lease.issuedAt.timeIntervalSinceReferenceDate
        let expires = lease.expiresAt.timeIntervalSinceReferenceDate
        let duration = lease.expiresAt.timeIntervalSince(lease.issuedAt)
        return SandboxVirtualMachineNamePolicy.isValid(lease.virtualMachineName)
            && lease.cpuCount > 0
            && lease.memoryBytes > 0
            && issued.isFinite
            && expires.isFinite
            && duration > 0
    }

    private static func openLockFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> Int32 {
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
            if created {
                guard fsync(descriptor) == 0 else {
                    throw SandboxCapacityError.io(errno)
                }
                guard fsync(directoryDescriptor) == 0 else {
                    throw SandboxCapacityError.publicationUncertain(errno)
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            if created {
                _ = unlinkat(directoryDescriptor, name, 0)
            }
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

    private static func pathError(_ code: Int32) -> SandboxCapacityError {
        switch code {
        case ELOOP, ENOTDIR:
            return .unsafeStatePath
        default:
            return .io(code)
        }
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
