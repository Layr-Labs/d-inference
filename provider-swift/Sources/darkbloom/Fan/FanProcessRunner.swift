import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct FanProcessResult: Equatable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

enum FanProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 15,
        discardStandardError: Bool = false,
        maximumOutputBytes: Int = 64 * 1024
    ) -> FanProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        let output = FanProcessOutputBox(maximumBytes: maximumOutputBytes)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        process.standardOutput = pipe
        // A caller that text-matches the output must not have a warning folded
        // into it: `lsof` complaining about `~/.ollama` would read as a running
        // Ollama and raise exactly the false WARN the contention probe forbids.
        process.standardError = discardStandardError ? FileHandle.nullDevice : pipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return FanProcessResult(status: -1, output: error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = finished.wait(timeout: .now() + 2)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            return FanProcessResult(
                status: -1,
                output: "command timed out after \(Int(timeout)) seconds"
            )
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return FanProcessResult(
            status: process.terminationStatus,
            output: output.string
        )
    }
}

private final class FanProcessOutputBox: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, maximumBytes - data.count)
        data.append(bytes.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
