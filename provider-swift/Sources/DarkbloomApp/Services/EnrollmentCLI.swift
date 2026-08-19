import Foundation

enum EnrollmentCLIStatus: String, Decodable, Equatable, Sendable {
    case alreadyEnrolled = "already_enrolled"
    case profileOpened = "profile_opened"
    case profileDownloaded = "profile_downloaded"
}

struct EnrollmentCLIResponse: Decodable, Equatable, Sendable {
    static let supportedSchema = 1

    let schema: Int
    let status: EnrollmentCLIStatus
    let serialNumber: String?
    let profilePath: String?
    let warning: String?

    init(
        schema: Int,
        status: EnrollmentCLIStatus,
        serialNumber: String?,
        profilePath: String?,
        warning: String? = nil
    ) {
        self.schema = schema
        self.status = status
        self.serialNumber = serialNumber
        self.profilePath = profilePath
        self.warning = warning
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case status
        case serialNumber = "serial_number"
        case profilePath = "profile_path"
        case warning
    }
}

enum EnrollmentCLIError: Error, Equatable, LocalizedError, Sendable {
    case cliNotFound
    case exited(Int32, message: String)
    case timedOut
    case unreadableOutput
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed. Reinstall Darkbloom, then try enrollment again."
        case .exited(let status, let message):
            message.isEmpty ? "Enrollment failed (exit \(status)). Try again." : message
        case .timedOut:
            "Enrollment did not finish in time. Check your connection, then try again."
        case .unreadableOutput:
            "The installed Darkbloom CLI returned enrollment data this app cannot read. Update Darkbloom, then try again."
        case .unsupportedSchema(let schema):
            "The enrollment response (schema \(schema)) is newer than this app understands. Update Darkbloom, then try again."
        }
    }
}

protocol EnrollmentCLIRunning: Sendable {
    func enroll() async throws -> EnrollmentCLIResponse
}

struct ProcessEnrollmentCLI: EnrollmentCLIRunning {
    private static let timeout: Duration = .seconds(120)
    private static let outputLimit = 1_048_576

    let locator: any DarkbloomCLILocating

    init(locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator()) {
        self.locator = locator
    }

    func enroll() async throws -> EnrollmentCLIResponse {
        guard let executable = locator.locate() else {
            throw EnrollmentCLIError.cliNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["enroll", "--json"]
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = EnrollmentOutputCollector(limit: Self.outputLimit)
        let stderr = EnrollmentOutputCollector(limit: 4_096)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.consumeAvailableData(from: $0) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.consumeAvailableData(from: $0) }

        let result = try await wait(
            for: process,
            cleanup: {
                stdout.finishReading(from: stdoutPipe.fileHandleForReading)
                stderr.finishReading(from: stderrPipe.fileHandleForReading)
            }
        )

        guard result == 0 else {
            throw EnrollmentCLIError.exited(result, message: stderr.lastLine)
        }
        guard let response = try? JSONDecoder().decode(EnrollmentCLIResponse.self, from: stdout.data) else {
            throw EnrollmentCLIError.unreadableOutput
        }
        guard response.schema == EnrollmentCLIResponse.supportedSchema else {
            throw EnrollmentCLIError.unsupportedSchema(response.schema)
        }
        return response
    }

    private func wait(
        for process: Process,
        cleanup: @escaping @Sendable () -> Void
    ) async throws -> Int32 {
        let guardBox = EnrollmentResumeGuard()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    cleanup()
                    let status = process.terminationStatus
                    let timedOut = guardBox.timedOut
                    let cancelled = guardBox.cancelled
                    guardBox.resume {
                        if timedOut {
                            continuation.resume(throwing: EnrollmentCLIError.timedOut)
                        } else if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: status)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    cleanup()
                    guardBox.resume { continuation.resume(throwing: error) }
                    return
                }

                guardBox.watchdog = Task {
                    try? await Task.sleep(for: Self.timeout)
                    guard !Task.isCancelled else { return }
                    guardBox.timedOut = true
                    if process.isRunning { process.terminate() }
                }
                if guardBox.isResumed { guardBox.watchdog?.cancel() }
            }
        } onCancel: {
            guardBox.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

private final class EnrollmentResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var timedOutStorage = false
    private var cancelledStorage = false

    var timedOut: Bool {
        get { lock.withLock { timedOutStorage } }
        set { lock.withLock { timedOutStorage = newValue } }
    }

    var cancelled: Bool {
        get { lock.withLock { cancelledStorage } }
        set { lock.withLock { cancelledStorage = newValue } }
    }

    var watchdog: Task<Void, Never>?
    var isResumed: Bool { lock.withLock { resumed } }

    func resume(_ body: () -> Void) {
        lock.lock()
        let wasResumed = resumed
        resumed = true
        let watchdog = watchdog
        lock.unlock()
        guard !wasResumed else { return }
        watchdog?.cancel()
        body()
    }
}

private final class EnrollmentOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func consumeAvailableData(from handle: FileHandle) {
        lock.withLock {
            guard !finished else { return }
            appendLocked(handle.availableData)
        }
    }

    /// Serializes handler delivery with the final post-exit drain. If a
    /// readability callback already owns the lock it appends first; otherwise
    /// the final drain wins and the callback observes `finished` without
    /// appending an out-of-order or duplicate tail.
    func finishReading(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.withLock {
            guard !finished else { return }
            finished = true
            appendLocked(handle.readDataToEndOfFile())
        }
    }

    var data: Data { lock.withLock { storage } }

    var lastLine: String {
        lock.withLock {
            String(decoding: storage, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .last ?? ""
        }
    }

    private func appendLocked(_ chunk: Data) {
        storage.append(chunk)
        if storage.count > limit { storage = storage.suffix(limit) }
    }
}
