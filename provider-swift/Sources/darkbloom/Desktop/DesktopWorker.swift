import Darwin
import Foundation
import ProviderCore

/// Runs only validated CLI argument arrays. No shell and no alternate runtime.
final class DesktopWorker: @unchecked Sendable {
  enum OutputCapture: Sendable {
    case combined
    /// Machine-readable output: discard stderr and reject truncated stdout.
    case standardOutput
  }

  enum RunError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning, outputLimitExceeded, outputReadFailed, inputTooLarge
    case timedOut(String)

    var description: String {
      switch self {
      case .alreadyRunning: return "A command is already running on this worker."
      case .outputLimitExceeded: return "Command stdout exceeded the capture limit."
      case .inputTooLarge: return "Command input exceeded the standard input limit."
      case .outputReadFailed: return "Could not read complete command stdout."
      case .timedOut(let output): return "Command timed out.\n\(output)"
      }
    }
  }

  private enum StopReason { case cancelled, timedOut }
  private final class Invocation: @unchecked Sendable {
    let process: Process
    // Protected by the worker's lock.
    var stopReason: StopReason?
    init(_ process: Process) { self.process = process }
  }

  private let lock = NSLock()
  private var invocation: Invocation?
  private var cancelled = false
  private var ended: (status: Int32, signaled: Bool)?
  private let executable: URL?
  /// How long a stopped child has between SIGTERM and SIGKILL: a second for ordinary commands, longer for one that
  /// first ends its own child, such as `sandbox setup --json-events`, whose installer gets SIGINT
  /// (`DesktopBackend.sandboxSetupGrace`).
  private let terminationGrace: TimeInterval

  init(executable: URL? = nil, terminationGrace: TimeInterval = 1) {
    self.executable = executable
    self.terminationGrace = terminationGrace
  }

  /// How the last child ended: its exit status, or the signal that ended it (`signaled`). Also after a cancel or a
  /// timeout, which `run` reports by throwing.
  var lastTermination: (status: Int32, signaled: Bool)? { lock.withLock { ended } }

  func cancel() {
    let current = lock.withLock {
      cancelled = true
      return invocation
    }
    if let current { stop(current, reason: .cancelled) }
  }

  /// `input` goes to the child's standard input, which then ends: a secret such as `route key --stdin`'s key, never an
  /// argument (at most 4 KiB, so it fits the pipe before the child starts). Without it the child reads the null device.
  /// `lines` gets each complete line of the captured output as it arrives, in order, on the reader's thread.
  func run(
    _ arguments: [String], timeout: TimeInterval = 3600,
    capture: OutputCapture = .combined, input: Data? = nil,
    lines: (@Sendable (String) -> Void)? = nil,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> (Int32, String) {
    try await execute(
      arguments, timeout: timeout, capture: capture, errors: nil, input: input, lines: lines, progress: progress)
  }

  /// Machine-readable stdout, as with `.standardOutput`, and the end of stderr kept apart (at most 8 KiB): the reason a
  /// command gives when its stdout is not the document it prints otherwise.
  func runReportingErrors(_ arguments: [String], timeout: TimeInterval) async throws
    -> (status: Int32, output: String, errors: String)
  {
    let errors = DesktopOutputBuffer(limit: 8192)
    let (status, output) = try await execute(
      arguments, timeout: timeout, capture: .standardOutput, errors: errors, input: nil, lines: nil,
      progress: { _ in })
    return (status, output, errors.text)
  }

  static let maximumInputBytes = 4096
  /// The output a run keeps: its last 32 KiB.
  static let outputLimit = 32_768

  private func execute(
    _ arguments: [String], timeout: TimeInterval, capture: OutputCapture, errors: DesktopOutputBuffer?,
    input: Data?, lines: (@Sendable (String) -> Void)?, progress: @escaping @Sendable (String) -> Void
  ) async throws -> (Int32, String) {
    let output = Pipe()
    let errorPipe = errors == nil ? nil : Pipe()
    let standardInput = try input.map(Self.filledPipe)
    let child = Process()
    child.executableURL = try executable ?? FanServiceManager().currentExecutableURL()
    child.arguments = arguments
    if let standardInput { child.standardInput = standardInput } else { child.standardInput = FileHandle.nullDevice }
    child.standardOutput = output
    // Ordinary actions retain their diagnostics. Probes need only stdout; the null device
    // also drains arbitrarily noisy stderr without another pipe or an unbounded buffer.
    if capture == .combined {
      child.standardError = output
    } else if let errorPipe {
      child.standardError = errorPipe
    } else {
      child.standardError = FileHandle.nullDevice
    }
    var environment = ProcessInfo.processInfo.environment
    environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
    environment["NO_COLOR"] = "1"
    child.environment = environment
    let buffer = DesktopOutputBuffer()
    let reader = DispatchGroup()
    let current = Invocation(child)
    reader.enter()
    if errorPipe != nil { reader.enter() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        child.terminationHandler = { process in
          reader.notify(queue: .global()) {
            let reason = self.lock.withLock {
              if self.invocation === current { self.invocation = nil }
              self.ended = (process.terminationStatus, process.terminationReason == .uncaughtSignal)
              return current.stopReason
            }
            child.terminationHandler = nil
            switch reason {
            case .cancelled: continuation.resume(throwing: CancellationError())
            case .timedOut: continuation.resume(throwing: RunError.timedOut(buffer.text))
            case nil:
              if capture == .standardOutput, buffer.readFailed {
                continuation.resume(throwing: RunError.outputReadFailed)
              } else if capture == .standardOutput, buffer.truncated {
                continuation.resume(throwing: RunError.outputLimitExceeded)
              } else {
                continuation.resume(returning: (process.terminationStatus, buffer.text))
              }
            }
          }
        }
        do {
          try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard invocation == nil else { throw RunError.alreadyRunning }
            try child.run()
            invocation = current
          }
          try? output.fileHandleForWriting.close()
          try? errorPipe?.fileHandleForWriting.close()
          try? standardInput?.fileHandleForReading.close()
          DispatchQueue.global().async {
            defer {
              try? output.fileHandleForReading.close()
              reader.leave()
            }
            var lastProgress = Date.distantPast
            var splitter = SandboxLineSplitter()
            do {
              // As soon as anything arrives: progress and `lines` follow the child while it runs (`readAvailable`).
              while true {
                let bytes = try output.fileHandleForReading.readAvailable(upToCount: 4096)
                if bytes.isEmpty { break }
                buffer.append(bytes)
                if let lines { splitter.append(bytes).forEach(lines) }
                let now = Date()
                if now.timeIntervalSince(lastProgress) >= 0.25 {
                  progress(buffer.text)
                  lastProgress = now
                }
              }
              if let lines, let rest = splitter.finish() { lines(rest) }
            } catch {
              buffer.markReadFailure()
            }
          }
          if let errorPipe, let errors {
            DispatchQueue.global().async {
              defer {
                try? errorPipe.fileHandleForReading.close()
                reader.leave()
              }
              while let bytes = try? errorPipe.fileHandleForReading.readDrained(upToCount: 4096), !bytes.isEmpty {
                errors.append(bytes)
              }
            }
          }
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak current] in
            guard let current else { return }
            // A completed probe's deadline must never cancel the next command on this worker.
            self?.stop(current, reason: .timedOut)
          }
        } catch {
          child.terminationHandler = nil
          try? output.fileHandleForWriting.close()
          try? output.fileHandleForReading.close()
          try? errorPipe?.fileHandleForWriting.close()
          try? errorPipe?.fileHandleForReading.close()
          try? standardInput?.fileHandleForReading.close()
          reader.leave()
          if errorPipe != nil { reader.leave() }
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  /// A pipe that already holds `input` and has ended: the child reads it, then end of file. Filled before the child
  /// starts, while this process still holds the read end, so the write can neither block nor raise SIGPIPE.
  private static func filledPipe(_ input: Data) throws -> Pipe {
    guard input.count <= maximumInputBytes else { throw RunError.inputTooLarge }
    let pipe = Pipe()
    defer { try? pipe.fileHandleForWriting.close() }
    try pipe.fileHandleForWriting.write(contentsOf: input)
    return pipe
  }

  private func stop(_ current: Invocation, reason: StopReason) {
    lock.withLock {
      guard invocation === current, current.process.isRunning else { return }
      if current.stopReason == nil { current.stopReason = reason }
      current.process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + terminationGrace) { [weak self, weak current] in
        guard let self, let current else { return }
        self.lock.withLock {
          guard self.invocation === current, current.process.isRunning else { return }
          // A child that ignores SIGTERM must not keep a probe or cancelled action alive.
          kill(current.process.processIdentifier, SIGKILL)
        }
      }
    }
  }
}

private final class DesktopOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()
  private var didTruncate = false
  private var didFailRead = false
  init(limit: Int = DesktopWorker.outputLimit) { self.limit = limit }
  func append(_ bytes: Data) {
    lock.withLock {
      data.append(bytes)
      if data.keepLast(limit) { didTruncate = true }
    }
  }
  func markReadFailure() { lock.withLock { didFailRead = true } }
  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
  var truncated: Bool { lock.withLock { didTruncate } }
  var readFailed: Bool { lock.withLock { didFailRead } }
}
