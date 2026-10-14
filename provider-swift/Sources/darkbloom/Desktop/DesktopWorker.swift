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
    case alreadyRunning, outputLimitExceeded, outputReadFailed
    case timedOut(String)

    var description: String {
      switch self {
      case .alreadyRunning: return "A command is already running on this worker."
      case .outputLimitExceeded: return "Command stdout exceeded the capture limit."
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
  private let executable: URL?

  init(executable: URL? = nil) { self.executable = executable }

  func cancel() {
    let current = lock.withLock {
      cancelled = true
      return invocation
    }
    if let current { stop(current, reason: .cancelled) }
  }

  func run(
    _ arguments: [String], timeout: TimeInterval = 3600,
    capture: OutputCapture = .combined,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> (Int32, String) {
    let output = Pipe()
    let child = Process()
    child.executableURL = try executable ?? FanServiceManager().currentExecutableURL()
    child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output
    // Ordinary actions retain their diagnostics. Probes need only stdout; the null device
    // also drains arbitrarily noisy stderr without another pipe or an unbounded buffer.
    child.standardError = capture == .combined ? output : FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
    environment["NO_COLOR"] = "1"
    child.environment = environment
    let buffer = DesktopOutputBuffer()
    let reader = DispatchGroup()
    let current = Invocation(child)
    reader.enter()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        child.terminationHandler = { process in
          reader.notify(queue: .global()) {
            let reason = self.lock.withLock {
              if self.invocation === current { self.invocation = nil }
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
          DispatchQueue.global().async {
            defer {
              try? output.fileHandleForReading.close()
              reader.leave()
            }
            var lastProgress = Date.distantPast
            do {
              while let bytes = try output.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
                buffer.append(bytes)
                let now = Date()
                if now.timeIntervalSince(lastProgress) >= 0.25 {
                  progress(buffer.text)
                  lastProgress = now
                }
              }
            } catch {
              buffer.markReadFailure()
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
          reader.leave()
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func stop(_ current: Invocation, reason: StopReason) {
    lock.withLock {
      guard invocation === current, current.process.isRunning else { return }
      if current.stopReason == nil { current.stopReason = reason }
      current.process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self, weak current] in
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
  private var data = Data()
  private var didTruncate = false
  private var didFailRead = false
  func append(_ bytes: Data) {
    lock.withLock {
      data.append(bytes)
      if data.count > 32_768 {
        data = data.suffix(32_768)
        didTruncate = true
      }
    }
  }
  func markReadFailure() { lock.withLock { didFailRead = true } }
  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
  var truncated: Bool { lock.withLock { didTruncate } }
  var readFailed: Bool { lock.withLock { didFailRead } }
}
