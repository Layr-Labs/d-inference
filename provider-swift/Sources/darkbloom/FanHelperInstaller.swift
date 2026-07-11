import FanControlIPC
import Foundation

enum FanHelperInstaller {
    enum InstallError: Error, LocalizedError {
        case packageMissing
        case signatureInvalid(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .packageMissing:
                return "this build does not contain the signed fan-helper package"
            case .signatureInvalid(let detail):
                return "fan-helper package signature is invalid: \(detail)"
            case .openFailed(let detail):
                return "could not open the fan-helper installer: \(detail)"
            }
        }
    }

    static func openInstaller() throws {
        let package = try packageURL()
        let signature = try run(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", package.path]
        )
        guard signature.status == 0,
              signature.output.contains("Developer ID Installer"),
              signature.output.contains(FanControlIPC.teamIdentifier) else {
            throw InstallError.signatureInvalid(
                signature.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }

        let assessment = try run(
            executable: "/usr/sbin/spctl",
            arguments: [
                "--assess",
                "--type", "install",
                "--verbose=2",
                package.path,
            ]
        )
        guard assessment.status == 0 else {
            throw InstallError.signatureInvalid(
                assessment.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }

        let opened = try run(
            executable: "/usr/bin/open",
            arguments: [package.path]
        )
        guard opened.status == 0 else {
            throw InstallError.openFailed(
                opened.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    static func packageURL(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) throws -> URL {
        let bundled = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("DarkbloomFanHelper.pkg")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        if let executableURL {
            let sibling = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent("DarkbloomFanHelper.pkg")
            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
        }
        throw InstallError.packageMissing
    }

    private static func run(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}
