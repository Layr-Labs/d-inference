import FanControlIPC
import Foundation

enum FanHelperInstaller {
    enum InstallError: Error, LocalizedError {
        case packageMissing
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .packageMissing:
                return "this build does not contain the signed fan-helper package"
            case .installFailed(let detail):
                return "fan-helper installation failed: \(detail)"
            }
        }
    }

    static func install() throws {
        let package = try packageURL()
        let command = installShellCommand(packagePath: package.path)
        let script = "do shell script \(appleScriptLiteral(command)) "
            + "with administrator privileges"
        let installed = try run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script]
        )
        guard installed.status == 0 else {
            throw InstallError.installFailed(
                installed.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    static func installShellCommand(packagePath: String) -> String {
        let source = shellQuote(packagePath)
        let requiredIdentity = shellQuote(
            "Developer ID Installer"
        )
        let requiredTeam = shellQuote(FanControlIPC.teamIdentifier)
        return [
            "set -eu",
            "umask 077",
            "STAGE=\"$(/usr/bin/mktemp -d "
                + "/private/var/tmp/darkbloom-fan.XXXXXXXX)\"",
            "cleanup() { /bin/rm -rf \"$STAGE\"; }",
            "trap cleanup 0 HUP INT TERM",
            "PKG=\"$STAGE/DarkbloomFanHelper.pkg\"",
            "/bin/cp \(source) \"$PKG\"",
            "/usr/sbin/chown root:wheel \"$PKG\"",
            "/bin/chmod 0600 \"$PKG\"",
            "SIGNATURE=\"$(/usr/sbin/pkgutil --check-signature "
                + "\"$PKG\" 2>&1)\"",
            "case \"$SIGNATURE\" in *\(requiredIdentity)*\(requiredTeam)*) "
                + ";; *) /bin/echo \"$SIGNATURE\" >&2; exit 65 ;; esac",
            "/usr/sbin/spctl --assess --type install --verbose=2 \"$PKG\"",
            "/usr/sbin/installer -pkg \"$PKG\" -target /",
        ].joined(separator: "; ")
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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\""
            + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
