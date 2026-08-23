import Foundation
import SandboxRuntimeVZ

struct EntitledRestoreImageProbe {
    private let testBundleURL: URL

    init(testBundleURL: URL) {
        self.testBundleURL = testBundleURL
    }

    func latestSupported() throws -> MacOSRestoreImageRecord {
        let daemonURL = testBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("darkbloom-sandboxd", isDirectory: false)
        let entitlementsURL = Self.packageDirectory
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DarkbloomSandbox.entitlements", isDirectory: false)

        try Self.requireFile(daemonURL, executable: true)
        try Self.requireFile(entitlementsURL, executable: false)

        try Self.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--sign", "-",
                "--entitlements", entitlementsURL.path,
                daemonURL.path,
            ]
        )
        try Self.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", daemonURL.path]
        )

        let output = try Self.run(
            daemonURL,
            arguments: ["restore-image", "latest", "--json"]
        )
        do {
            return try JSONDecoder().decode(MacOSRestoreImageRecord.self, from: output)
        } catch {
            throw EntitledRestoreImageProbeError.invalidOutput(
                String(data: output, encoding: .utf8) ?? "<non-UTF-8 output>",
                String(describing: error)
            )
        }
    }

    private static var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func requireFile(_ url: URL, executable: Bool) throws {
        let exists = executable
            ? FileManager.default.isExecutableFile(atPath: url.path)
            : FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            throw EntitledRestoreImageProbeError.missingFile(url.path)
        }
    }

    @discardableResult
    private static func run(_ executableURL: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw EntitledRestoreImageProbeError.launchFailed(
                executableURL.path,
                String(describing: error)
            )
        }

        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw EntitledRestoreImageProbeError.commandFailed(
                executableURL.path,
                process.terminationStatus,
                String(data: errorOutput, encoding: .utf8) ?? "<non-UTF-8 stderr>"
            )
        }
        return output
    }
}

private enum EntitledRestoreImageProbeError: Error, CustomStringConvertible {
    case missingFile(String)
    case launchFailed(String, String)
    case commandFailed(String, Int32, String)
    case invalidOutput(String, String)

    var description: String {
        switch self {
        case .missingFile(let path):
            return "required live restore test file is missing: \(path)"
        case .launchFailed(let executable, let message):
            return "failed to launch \(executable): \(message)"
        case .commandFailed(let executable, let status, let standardError):
            return "\(executable) exited with status \(status): \(standardError)"
        case .invalidOutput(let output, let message):
            return "restore probe returned invalid JSON (\(message)): \(output)"
        }
    }
}
