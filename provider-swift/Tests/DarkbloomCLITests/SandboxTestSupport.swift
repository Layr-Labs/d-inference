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

/// `darkbloom-sandbox status --json` documents (schema 1) as add-on 1.0.1
/// writes them (sorted keys, every member present), for the states the CLI
/// renders, plus a future schema and the minimum it accepts.
enum SandboxFixtures {
    static let lastUpdateCheck: TimeInterval = 1_793_000_000
    static let host = "0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60"

    static let ready = #"""
    {"accepting":true,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","detail":"Ready for jobs (free slots: Linux 1 of 1, macOS 1 of 1)","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","images":[{"platform":"linux","progress":null,"state":"installed"},{"platform":"macos","progress":null,"state":"installed"}],"installed":true,"jobs_running":0,"last_update_check":1793000000,"schema":1,"slots":{"linux":{"free":1,"total":1},"macos":{"free":1,"total":1}},"state":"ready","version":"1.0.1"}
    """#

    static let running = #"""
    {"accepting":true,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","detail":"Running 1 job","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","images":[{"platform":"linux","progress":null,"state":"installed"},{"platform":"macos","progress":null,"state":"installed"}],"installed":true,"jobs_running":1,"last_update_check":1793000000,"schema":1,"slots":{"linux":{"free":0,"total":1},"macos":{"free":1,"total":1}},"state":"running","version":"1.0.1"}
    """#

    static let paused = #"""
    {"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","detail":"Paused by you: no new jobs, 1 job finishing; resume with darkbloom-sandbox resume","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","images":[{"platform":"linux","progress":null,"state":"installed"},{"platform":"macos","progress":null,"state":"installed"}],"installed":true,"jobs_running":1,"last_update_check":null,"schema":1,"slots":{"linux":{"free":0,"total":1},"macos":{"free":0,"total":1}},"state":"paused","version":"1.0.1"}
    """#

    static let downloading = #"""
    {"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","detail":"Downloading its linux image: 42%","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","images":[{"platform":"linux","progress":0.42,"state":"downloading"},{"platform":"macos","progress":null,"state":"missing"}],"installed":true,"jobs_running":0,"last_update_check":1793000000,"schema":1,"slots":{"linux":{"free":1,"total":1},"macos":{"free":1,"total":1}},"state":"downloading_images","version":"1.0.1"}
    """#

    static let waiting = #"""
    {"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs","detail":"Approve this Mac at https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT (code WDJB-MJHT)","host_id":null,"images":[],"installed":true,"jobs_running":0,"last_update_check":null,"schema":1,"slots":{"linux":{"free":0,"total":1},"macos":{"free":0,"total":1}},"state":"waiting_for_approval","version":"1.0.1"}
    """#

    static let error = #"""
    {"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","detail":"Not connected to the plane (cannot reach the plane); it keeps trying","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","images":[],"installed":true,"jobs_running":0,"last_update_check":1793000000,"schema":1,"slots":{"linux":{"free":0,"total":1},"macos":{"free":0,"total":1}},"state":"error","version":"1.0.1"}
    """#

    static let notInstalled = #"""
    {"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs","detail":"Darkbloom Sandbox is not installed in /Users/ada/DarkbloomSandbox","host_id":null,"images":[],"installed":false,"jobs_running":0,"last_update_check":null,"schema":1,"slots":{"linux":{"free":0,"total":0},"macos":{"free":0,"total":0}},"state":"not_installed","version":"1.0.1"}
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
        /// Add-on 1.0.1's command with nothing installed under it: `status`
        /// exits 1 (its JSON says `not_installed`), `pause` and `resume` refuse.
        case empty
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
        case .empty:
            return """
            #!/bin/sh
            case "$1" in
            status) if [ "${2:-}" = --json ]; then printf '%s\\n' '\(SandboxFixtures.notInstalled)'; else echo 'Darkbloom Sandbox is not installed.'; fi; exit 1 ;;
            pause|resume) echo 'error: Darkbloom Sandbox is not installed in /Users/ada/DarkbloomSandbox' >&2; exit 1 ;;
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
    /// A first install as add-on 1.0.1 reports it with `--json-progress`
    /// (sorted keys; the bootstrap's own events carry no extra fields).
    static let events = [
        #"{"event":"stage","message":"Checking this Mac","schema":1,"stage":"checking_mac","status":"started","step":1,"steps":8}"#,
        #"{"event":"stage","message":"Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1; logged in as ada","schema":1,"stage":"checking_mac","status":"done","step":1,"steps":8}"#,
        #"{"event":"stage","message":"Verifying release","schema":1,"stage":"verifying_release","status":"started","step":2,"steps":8}"#,
        #"{"event":"stage","message":"Downloaded 1.0.1 from https://api-sandbox.darkbloom.dev: the archive matches its manifest, the app is Darkbloom's (team SLDQ2GJ6TL)","schema":1,"stage":"verifying_release","status":"progress","step":2,"steps":8}"#,
        #"{"event":"stage","message":"Darkbloom Sandbox 1.0.1, signed by Darkbloom (Developer ID team SLDQ2GJ6TL); the release's signature checks out","schema":1,"stage":"verifying_release","status":"done","step":2,"steps":8,"version":"1.0.1"}"#,
        #"{"event":"stage","message":"Installing","schema":1,"stage":"installing","status":"started","step":3,"steps":8}"#,
        #"{"event":"stage","message":"~/DarkbloomSandbox: 1 Linux slot and 1 macOS slot","root":"/Users/ada/DarkbloomSandbox","schema":1,"slots":{"linux":1,"macos":1},"stage":"installing","status":"done","step":3,"steps":8}"#,
        #"{"event":"stage","message":"Waiting for approval","schema":1,"stage":"waiting_for_approval","status":"started","step":4,"steps":8}"#,
        #"{"browser_opened":false,"event":"stage","message":"Open https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT in a browser\n(or go to https://api-sandbox.darkbloom.dev/device and enter the code WDJB-MJHT),\nsign in with the Darkbloom account that will own this Mac, check the Mac shown and press Approve.","schema":1,"stage":"waiting_for_approval","status":"progress","step":4,"steps":8,"user_code":"WDJB-MJHT","verification_uri":"https://api-sandbox.darkbloom.dev/device","verification_uri_complete":"https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT"}"#,
        #"{"event":"stage","message":"Approved after 0:42","schema":1,"stage":"waiting_for_approval","status":"done","step":4,"steps":8}"#,
        #"{"event":"stage","message":"Enrolled","schema":1,"stage":"enrolled","status":"started","step":5,"steps":8}"#,
        #"{"app_attest_key":"k1","event":"stage","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","message":"Host 0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60; App Attest verified this app","schema":1,"stage":"enrolled","status":"done","step":5,"steps":8}"#,
        #"{"event":"stage","message":"Starting","schema":1,"stage":"starting","status":"started","step":6,"steps":8}"#,
        #"{"connected":true,"event":"stage","message":"Connected to https://api-sandbox.darkbloom.dev","schema":1,"stage":"starting","status":"done","step":6,"steps":8}"#,
        #"{"event":"stage","message":"Downloading images","schema":1,"stage":"downloading_images","status":"started","step":7,"steps":8}"#,
        #"{"event":"stage","installed":[],"message":"In the background (about 13 GB for Linux and 42 GB for macOS)","schema":1,"stage":"downloading_images","status":"done","step":7,"steps":8}"#,
        #"{"event":"stage","message":"Ready","schema":1,"stage":"ready","status":"started","step":8,"steps":8}"#,
        #"{"accepting":false,"event":"stage","message":"Not yet: this Mac takes jobs once its first image is installed","schema":1,"stage":"ready","state":"downloading_images","status":"done","step":8,"steps":8}"#,
        #"{"accepting":false,"console_url":"https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","event":"summary","host_id":"0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60","ok":true,"schema":1,"slots":{"linux":{"automatic":true,"count":1,"limit":"cores"},"macos":{"automatic":true,"count":1,"limit":"cores"}},"state":"downloading_images","status_command":"/Users/ada/DarkbloomSandbox/darkbloom-sandbox status --json"}"#,
    ]

    /// The `plan` event as add-on 1.1.1 writes it for `--plan --json-progress`;
    /// by default for a 16-core, 128 GB Mac running inference with 157 GiB
    /// free on a 1858 GiB volume.
    static func plan(message: String = "1 Linux slot", linux: Int = 1, macOS: Int = 0, linuxAutomatic: Bool = true,
                     freeGiB: Int64 = 157, extra: String = "") -> String {
        func gib(_ count: Int64) -> Int64 { count << 30 }
        return #"{"schema":1,"event":"plan","message":"\#(message)","root":"/Users/ada/DarkbloomSandbox","#
            + #""linux_slots":\#(linux),"macos_slots":\#(macOS),"linux_automatic":\#(linuxAutomatic),"#
            + #""macos_automatic":true,"linux_limit":"free disk space","macos_limit":"free disk space","#
            + #""free_bytes":\#(gib(freeGiB)),"volume_bytes":\#(gib(1_858)),"floor_bytes":\#(gib(100)),"#
            + #""linux_images_bytes":\#(gib(4)),"macos_images_bytes":\#(gib(46)),"linux_slot_bytes":\#(gib(30)),"#
            + #""macos_slot_bytes":\#(gib(40)),"cores":16,"cores_kept":4,"memory_bytes":\#(gib(128)),"#
            + #""memory_kept_bytes":\#(gib(32)),"provider_memory_bytes":\#(gib(32))\#(extra)}"#
    }

    /// `plan` lines make it an installer with plan mode (add-on 1.1.1): with
    /// `--plan` it records its arguments, prints them, installs nothing and
    /// exits with `planExitStatus`. Without, the script never names `--plan`.
    static func script(events: [String] = events, plan: [String]? = nil, planExitStatus: Int32 = 0,
                       addonStatus: String = SandboxFixtures.downloading, standardError: String? = nil,
                       exitStatus: Int32 = 0, jsonProgress: Bool = true) -> String {
        let header = jsonProgress ? "# Understands --json-progress." : "# An installer from before progress events."
        let plain = jsonProgress ? "" : "echo '==> Darkbloom Sandbox 1.0.0 downloaded and checked'"
        let planMode = plan.map { lines in
            """
            if [ "${1:-}" = \(SandboxInstaller.planOption) ]; then
            printf '%s\\n' "$@" > "$root/plan-arguments"
            \(lines.map { "printf '%s\\n' \(quoted($0))" }.joined(separator: "\n"))
            exit \(planExitStatus)
            fi
            """
        } ?? ""
        return """
        #!/bin/sh
        \(header)
        set -eu
        root="$DARKBLOOM_SANDBOX_ROOT"
        mkdir -p "$root"
        \(planMode)
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

    /// A stage event as add-on 1.0.1 writes it.
    static func stage(_ id: String, _ status: String, _ message: String, _ fields: String = "") -> String {
        let extra = fields.isEmpty ? "" : "," + fields
        return #"{"event":"stage","message":"\#(message)","schema":1,"stage":"\#(id)","status":"\#(status)"\#(extra)}"#
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
