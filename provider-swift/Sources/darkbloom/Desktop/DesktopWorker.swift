import Foundation
import ProviderCore

/// Runs only validated CLI argument arrays. No shell and no alternate runtime.
final class DesktopWorker: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private let executable: URL?

  init(executable: URL? = nil) { self.executable = executable }

  func cancel() {
    lock.withLock {
      cancelled = true
      if let process, process.isRunning { process.terminate() }
    }
  }

  func run(
    _ arguments: [String], timeout: TimeInterval = 3600,
    progress: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> (Int32, String) {
    let output = Pipe()
    let child = Process()
    child.executableURL = try executable ?? FanServiceManager().currentExecutableURL()
    child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output
    child.standardError = output
    var environment = ProcessInfo.processInfo.environment
    environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
    environment["NO_COLOR"] = "1"
    child.environment = environment
    let buffer = DesktopOutputBuffer()
    let reader = DispatchGroup()
    reader.enter()
    return try await withCheckedThrowingContinuation { continuation in
      child.terminationHandler = { process in
        reader.notify(queue: .global()) {
          continuation.resume(returning: (process.terminationStatus, buffer.text))
        }
      }
      do {
        try lock.withLock {
          guard !cancelled else { throw CancellationError() }
          try child.run()
          process = child
        }
        DispatchQueue.global().async {
          defer {
            reader.leave()
            try? output.fileHandleForReading.close()
          }
          var lastProgress = Date.distantPast
          while let bytes = try? output.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
            buffer.append(bytes)
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 0.25 {
              progress(buffer.text)
              lastProgress = now
            }
          }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak child] in
          guard let child, child.isRunning else { return }
          self?.cancel()
        }
      } catch {
        child.terminationHandler = nil
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        reader.leave()
        continuation.resume(throwing: error)
      }
    }
  }
}

private final class DesktopOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ bytes: Data) {
    lock.withLock {
      data.append(bytes)
      if data.count > 32_768 { data = data.suffix(32_768) }
    }
  }
  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
