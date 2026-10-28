import ArgumentParser
import Foundation

@testable import darkbloom

/// For an exit test: runs a command's `body` and exits with the status the
/// CLI would (an `ExitCode` it throws, 1 for another error, else 0).
func exitWithCommandStatus(_ body: () async throws -> Void) async -> Never {
    do {
        try await body()
        exit(0)
    } catch let code as ExitCode {
        exit(code.rawValue)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
}

/// `darkbloom-sandbox status --json` documents (schema 1) for the states the
/// CLI renders, plus a future schema and the minimum it accepts.
enum SandboxFixtures {
    static let lastUpdateCheck: TimeInterval = 1_793_000_000

    static let ready = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":"h_8f2c1a","state":"ready","detail":"","slots":{"linux":{"total":1,"free":1},"macos":{"total":1,"free":1}},"jobs_running":0,"images":[{"platform":"linux_arm64","state":"installed","progress":null},{"platform":"macos_arm64","state":"installed","progress":null}],"accepting":true,"last_update_check":1793000000,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let running = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":"h_8f2c1a","state":"running","detail":"","slots":{"linux":{"total":1,"free":0},"macos":{"total":1,"free":1}},"jobs_running":1,"images":[{"platform":"linux_arm64","state":"installed","progress":null},{"platform":"macos_arm64","state":"installed","progress":null}],"accepting":true,"last_update_check":1793000000,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let paused = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":"h_8f2c1a","state":"paused","detail":"","slots":{"linux":{"total":1,"free":0},"macos":{"total":1,"free":1}},"jobs_running":1,"images":[],"accepting":false,"last_update_check":null,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let downloading = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":"h_8f2c1a","state":"downloading_images","detail":"","slots":{"linux":{"total":1,"free":1},"macos":{"total":1,"free":1}},"jobs_running":0,"images":[{"platform":"linux_arm64","state":"installed","progress":null},{"platform":"macos_arm64","state":"downloading","progress":0.42}],"accepting":true,"last_update_check":1793000000,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let waiting = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":null,"state":"waiting_for_approval","detail":"","slots":{"linux":{"total":0,"free":0},"macos":{"total":0,"free":0}},"jobs_running":0,"images":[],"accepting":false,"last_update_check":null,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let error = #"""
    {"schema":1,"installed":true,"version":"1.2.0","host_id":"h_8f2c1a","state":"error","detail":"the macOS image failed verification","slots":{"linux":{"total":1,"free":1},"macos":{"total":1,"free":1}},"jobs_running":0,"images":[],"accepting":false,"last_update_check":1793000000,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let notInstalled = #"""
    {"schema":1,"installed":false,"version":"1.2.0","host_id":null,"state":"not_installed","detail":"","slots":{"linux":{"total":0,"free":0},"macos":{"total":0,"free":0}},"jobs_running":0,"images":[],"accepting":false,"last_update_check":null,"console_url":"https://api-sandbox.darkbloom.dev"}
    """#

    static let future = #"{"schema":2,"state":"hibernating","detail":"Sleeping until 22:00","jobs_running":0}"#

    static let minimal = #"{"schema":1,"state":"ready"}"#

    static func status(_ json: String) -> SandboxAddonStatus {
        guard let status = SandboxAddonStatus(json: json) else { fatalError("fixture does not decode: \(json)") }
        return status
    }
}

/// A fake `darkbloom-sandbox` command: a shell script the CLI runs exactly as
/// it runs the add-on.
enum FakeSandboxAddon {
    enum Kind {
        /// Answers `status --json` with `status`; `pause`, `resume` and
        /// `uninstall --yes` succeed, other actions get the usage.
        case current(status: String)
        /// An add-on from before `status --json`: plain `status` only.
        case outdated
        case hanging
        case failing(String)
    }

    static func script(_ kind: Kind) -> String {
        switch kind {
        case .current(let status):
            return """
            #!/bin/sh
            here=${0%/*}
            case "$1" in
            status) if [ "${2:-}" = --json ]; then printf '%s\\n' '\(status)'; else echo 'human status'; fi ;;
            pause|resume) echo "$1" > "$here/last-action" ;;
            uninstall) [ "${2:-}" = --yes ] || exit 9; echo '==> Removed.'; rm -rf "$here" ;;
            *) echo 'usage: darkbloom-sandbox install [--server <url>]' >&2; exit 64 ;;
            esac
            """
        case .outdated:
            return """
            #!/bin/sh
            if [ "$1" = status ] && [ $# -eq 1 ]; then echo 'Darkbloom Sandbox 0.9.0 in ~/DarkbloomSandbox'; exit 0; fi
            echo 'usage: darkbloom-sandbox install [--server <url>]' >&2
            exit 64
            """
        case .hanging:
            return "#!/bin/sh\nexec sleep 30\n"
        case .failing(let message):
            return "#!/bin/sh\necho '\(message)' >&2\nexit 1\n"
        }
    }

    @discardableResult
    static func install(_ kind: Kind, at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let command = root.appendingPathComponent("darkbloom-sandbox")
        try Data(script(kind).utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return command
    }

    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-addon-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }
}

/// A fake `install.sh`: it records its arguments, installs a fake add-on into
/// `DARKBLOOM_SANDBOX_ROOT`, prints `events` and exits with `exitStatus`.
enum FakeSandboxInstaller {
    static let events = [
        #"{"schema":1,"stage":"checking"}"#,
        #"{"schema":1,"stage":"verifying","version":"1.2.0"}"#,
        #"{"schema":1,"stage":"installing","detail":"Linux slots: 1"}"#,
        #"{"schema":1,"stage":"waiting_for_approval","url":"https://sandbox.invalid/device?user_code=WXYZ-1234","code":"WXYZ-1234","expires_in":900}"#,
        #"{"schema":1,"stage":"enrolled","host_id":"h_test"}"#,
        #"{"schema":1,"stage":"starting"}"#,
        #"{"schema":1,"stage":"downloading_images","progress":0.42}"#,
    ]

    static func script(events: [String] = events, addonStatus: String = SandboxFixtures.ready,
                       standardError: String? = nil, exitStatus: Int32 = 0, jsonProgress: Bool = true) -> String {
        let header = jsonProgress ? "# Understands --json-progress." : "# An installer from before progress events."
        let plain = jsonProgress ? "" : "echo '==> Darkbloom Sandbox 1.1.0 downloaded and checked'"
        return """
        #!/bin/sh
        \(header)
        set -eu
        root="$DARKBLOOM_SANDBOX_ROOT"
        mkdir -p "$root"
        printf '%s\\n' "$@" > "$root/installer-arguments"
        cat > "$root/darkbloom-sandbox" <<'ADDON'
        \(FakeSandboxAddon.script(.current(status: addonStatus)))
        ADDON
        chmod 755 "$root/darkbloom-sandbox"
        \(plain)
        \(events.map { "printf '%s\\n' \(quoted($0))" }.joined(separator: "\n"))
        \(standardError.map { "echo \(quoted($0)) >&2" } ?? "")
        exit \(exitStatus)
        """
    }

    /// One shell word.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }
}

extension SandboxHostFacts {
    /// A plugged-in Mac on Ethernet that never sleeps, with room on disk.
    static func mac(cores: Int, memoryGiB: Int64, provider: Bool = true, freeGiB: Int64 = 800,
                    volumeGiB: Int64 = 2_000) -> SandboxHostFacts {
        SandboxHostFacts(
            chip: "Apple M4 Max", appleSilicon: true, macOSVersion: "27.0.1", macOSMajor: 27, cores: cores,
            memoryBytes: memoryGiB << 30, volumeBytes: volumeGiB << 30, freeBytes: freeGiB << 30,
            imagesInstalled: false, providerRunning: provider, network: .ethernet, power: .noBattery,
            sleepMinutes: 0)
    }
}
