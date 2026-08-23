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
    private static let lockFileName = "capacity.lock"
    private static let maximumStateBytes = 1_048_576

    private let stateDirectory: URL

    init(stateDirectory: URL) throws {
        guard stateDirectory.isFileURL,
              stateDirectory.baseURL == nil,
              stateDirectory.path.hasPrefix("/")
        else {
            throw SandboxCapacityError.unsafeStatePath
        }
        self.stateDirectory = stateDirectory.standardizedFileURL
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

        let lockDescriptor = openat(
            directoryDescriptor,
            Self.lockFileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard lockDescriptor >= 0 else {
            throw Self.pathError(errno)
        }
        defer { close(lockDescriptor) }
        try Self.validateFileDescriptor(lockDescriptor)
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
        defer { flock(lockDescriptor, LOCK_UN) }
        return try operation(directoryDescriptor)
    }

    private func openStateDirectory() throws -> Int32 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: stateDirectory.path,
            isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue else {
                throw SandboxCapacityError.unsafeStatePath
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw SandboxCapacityError.io(errno)
            }
        }

        let descriptor = open(
            stateDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw Self.pathError(errno)
        }
        do {
            try Self.validateDirectoryDescriptor(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
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
        try Self.validateFileDescriptor(descriptor)
        let data = try Self.readAll(
            descriptor,
            maximumBytes: Self.maximumStateBytes
        )
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
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SandboxCapacityError.io(errno)
        }
        var descriptorIsOpen = true
        var shouldRemove = true
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if shouldRemove {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
        let closeStatus = close(descriptor)
        descriptorIsOpen = false
        guard closeStatus == 0 else {
            throw SandboxCapacityError.io(errno)
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
        guard fsync(directoryDescriptor) == 0 else {
            throw SandboxCapacityError.io(errno)
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

    private static func validateDirectoryDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw SandboxCapacityError.unsafeStatePath
        }
    }

    private static func validateFileDescriptor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SandboxCapacityError.io(errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw SandboxCapacityError.unsafeStatePath
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

    private static func readAll(
        _ descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                return result
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw SandboxCapacityError.io(errno)
            }
            guard result.count + count <= maximumBytes else {
                throw SandboxCapacityError.corruptState
            }
            result.append(buffer, count: count)
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
