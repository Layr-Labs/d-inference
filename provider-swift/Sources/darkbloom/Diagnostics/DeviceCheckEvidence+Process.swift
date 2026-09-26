import Foundation

extension DeviceCheckEvidence {
    /// File-backed output avoids pipe backpressure. Both the command and its
    /// termination grace are bounded; Process reaps a killed child asynchronously.
    static func runLog(
        _ arguments: [String],
        executable: URL = URL(fileURLWithPath: "/usr/bin/log"),
        timeout: TimeInterval = timeoutSeconds,
        terminationGrace: TimeInterval = 0.25,
        directory: URL = FileManager.default.temporaryDirectory
    ) throws -> (status: Int32, stdout: Data, stderr: String) {
        let out = directory.appendingPathComponent("darkbloom-devicecheck-\(UUID().uuidString).out")
        let err = directory.appendingPathComponent("darkbloom-devicecheck-\(UUID().uuidString).err")
        defer { for url in [out, err] { try? FileManager.default.removeItem(at: url) } }
        for url in [out, err] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let stdout = try FileHandle(forWritingTo: out)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: err)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + max(0, terminationGrace)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "timed out after \(timeout)s"])
        }
        let errorText = String(decoding: (try? Data(contentsOf: err)) ?? Data(), as: UTF8.self)
        return (process.terminationStatus, (try? Data(contentsOf: out)) ?? Data(), errorText)
    }
}
