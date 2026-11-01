import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("darkbloom sandbox status")
struct SandboxStatusTests {
    @Test("schema 1 as add-on 1.0.1 writes it decodes every field; missing fields and unknown states still decode")
    func decoding() throws {
        let ready = SandboxFixtures.status(SandboxFixtures.ready)
        #expect(ready == SandboxAddonStatus(
            schema: 1, installed: true, version: "1.0.1", hostID: SandboxFixtures.host, state: .ready,
            detail: "Ready for jobs (free slots: Linux 1 of 1, macOS 1 of 1)",
            linux: .init(total: 1, free: 1), macOS: .init(total: 1, free: 1), jobsRunning: 0,
            images: [.init(platform: "linux", state: "installed", progress: nil),
                     .init(platform: "macos", state: "installed", progress: nil)],
            accepting: true, lastUpdateCheck: Date(timeIntervalSince1970: SandboxFixtures.lastUpdateCheck),
            consoleURL: "https://api-sandbox.darkbloom.dev/macs/\(SandboxFixtures.host)"))
        #expect(ready.imagesInstalled)

        let downloading = SandboxFixtures.status(SandboxFixtures.downloading)
        #expect(downloading.state == .downloadingImages)
        #expect(downloading.downloadingImage == .init(platform: "linux", state: "downloading", progress: 0.42))
        #expect(!downloading.imagesInstalled)

        let absent = SandboxFixtures.status(SandboxFixtures.notInstalled)
        #expect(!absent.installed && absent.state == .notInstalled && absent.hostID == nil)

        let minimal = SandboxFixtures.status(SandboxFixtures.minimal)
        #expect(minimal.installed && minimal.state == .ready && minimal.jobsRunning == 0 && minimal.images.isEmpty)
        #expect(minimal.linux == nil && minimal.version == nil && minimal.lastUpdateCheck == nil)

        let future = SandboxFixtures.status(SandboxFixtures.future)
        #expect(future.schema == 2 && future.state == .unknown("hibernating"))
        #expect(future.detail == "Sleeping until 22:00")

        #expect(SandboxAddonStatus(json: "not json") == nil)
        #expect(SandboxAddonStatus(json: #"{"schema":0,"state":"ready"}"#) == nil)
        #expect(SandboxAddonStatus(json: #"{"schema":1}"#) == nil)
        #expect(SandboxAddonStatus(json: "usage: darkbloom-sandbox install") == nil)
        // Free slots never exceed the total; progress stays within 0...1.
        let odd = try #require(SandboxAddonStatus(json: #"""
            {"schema":1,"state":"ready","slots":{"linux":{"total":1,"free":5}},"images":[{"platform":"x","state":"downloading","progress":7}]}
            """#))
        #expect(odd.linux == .init(total: 1, free: 1))
        #expect(odd.images.first?.progress == 1)
    }

    @Test("last_update_check accepts Unix seconds, milliseconds and ISO 8601")
    func timestamps() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(SandboxAddonStatus.timestamp(1_793_000_000) == date)
        #expect(SandboxAddonStatus.timestamp(1_793_000_000_000.0) == date)
        #expect(SandboxAddonStatus.timestamp("2026-10-26T07:33:20Z") == date)
        #expect(SandboxAddonStatus.timestamp("2026-10-26T07:33:20.000Z") == date)
        #expect(SandboxAddonStatus.timestamp(nil) == nil)
        #expect(SandboxAddonStatus.timestamp("yesterday") == nil)
    }

    @Test("a ready Mac renders one complete screen")
    func readyScreen() {
        let now = Date(timeIntervalSince1970: SandboxFixtures.lastUpdateCheck + 720)
        #expect(SandboxStatusView.lines(SandboxFixtures.status(SandboxFixtures.ready), now: now) == [
            "Darkbloom Sandbox 1.0.1: ready",
            "  Waiting for jobs. Inference runs as usual until a job starts.",
            "  Free slots: Linux 1 of 1, macOS 1 of 1",
            "  Images: Linux installed, macOS installed",
            "  Host: \(SandboxFixtures.host)",
            "  Updates: automatic, last checked 12m ago",
            "  Console: https://api-sandbox.darkbloom.dev/macs/\(SandboxFixtures.host) (jobs and earnings)",
            "  Pause: darkbloom sandbox pause (running jobs finish; no new ones)",
            "  Logs: darkbloom sandbox logs",
        ])
    }

    @Test("each state says what it means for inference, or the add-on's own detail, and what to run next")
    func states() {
        func screen(_ json: String) -> [String] { SandboxStatusView.lines(SandboxFixtures.status(json)) }
        let running = screen(SandboxFixtures.running)
        #expect(running[0] == "Darkbloom Sandbox 1.0.1: running 1 job")
        #expect(running[1] == "  Inference is paused while jobs run, and resumes after the last one ends.")
        #expect(running[2] == "  Free slots: Linux 0 of 1, macOS 1 of 1")

        let paused = screen(SandboxFixtures.paused)
        #expect(paused[0] == "Darkbloom Sandbox 1.0.1: paused")
        #expect(paused[1] == "  1 job still running; it finishes normally. No new jobs until you run `darkbloom sandbox resume`.")
        #expect(paused.contains("  Free slots: Linux 0 of 1, macOS 0 of 1"))
        #expect(paused.contains("  Resume: darkbloom sandbox resume"))
        #expect(paused.contains("  Updates: automatic, not checked yet"))

        let downloading = screen(SandboxFixtures.downloading)
        #expect(downloading[0] == "Darkbloom Sandbox 1.0.1: downloading images (Linux 42%)")
        #expect(downloading[1] == "  Downloading its linux image: 42%")
        #expect(downloading[2] == "  Images: Linux downloading 42%, macOS missing")
        #expect(!downloading.contains { $0.hasPrefix("  Free slots:") })

        let waiting = screen(SandboxFixtures.waiting)
        #expect(waiting[0] == "Darkbloom Sandbox 1.0.1: waiting for approval")
        #expect(waiting[1] == "  Approve this Mac at https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT (code WDJB-MJHT)")
        #expect(!waiting.contains { $0.hasPrefix("  Free slots:") || $0.hasPrefix("  Host:") })
        #expect(waiting.contains("  Follow the setup: darkbloom sandbox setup"))

        let error = screen(SandboxFixtures.error)
        #expect(error[0] == "Darkbloom Sandbox 1.0.1: error")
        #expect(error[1] == "  Not connected to the plane (cannot reach the plane); it keeps trying")
        #expect(error.contains("  Repair: darkbloom sandbox setup"))

        var stopped = SandboxFixtures.status(SandboxFixtures.error)
        stopped.state = .stopped
        #expect(SandboxStatusView.lines(stopped)[1]
            == "  The agent is not running, so this Mac gets no jobs. Run `darkbloom sandbox setup` to start it.")

        let future = screen(SandboxFixtures.future)
        #expect(future[0] == "Darkbloom Sandbox: hibernating")
        #expect(future[1] == "  Sleeping until 22:00")
        var silent = SandboxFixtures.status(SandboxFixtures.future)
        silent.detail = nil
        #expect(SandboxStatusView.lines(silent)[1]
            == "  Your add-on is newer than this CLI. Run `darkbloom update` for a matching CLI.")
    }

    @Test("color marks the state only when enabled")
    func color() {
        let plain = SandboxStatusView.lines(SandboxFixtures.status(SandboxFixtures.error), color: false)
        let colored = SandboxStatusView.lines(SandboxFixtures.status(SandboxFixtures.error), color: true)
        #expect(!plain[0].contains("\u{1B}["))
        #expect(colored[0] == "Darkbloom Sandbox 1.0.1: \u{1B}[1;31merror\u{1B}[0m")
    }

    @Test("darkbloom status gets one line when the add-on is installed, and none when it is not")
    func statusLine() {
        func line(_ json: String) -> String? {
            SandboxStatusView.statusLine(.status(SandboxFixtures.status(json), json: json))
        }
        let details = " Run `darkbloom sandbox status` for details."
        #expect(SandboxStatusView.statusLine(.notInstalled) == nil)
        #expect(line(SandboxFixtures.notInstalled) == nil)
        #expect(line(SandboxFixtures.ready) == "Sandboxes: ready, no jobs running; free slots Linux 1/1, macOS 1/1")
        #expect(line(SandboxFixtures.running) == "Sandboxes: running 1 job; free slots Linux 0/1, macOS 1/1")
        #expect(line(SandboxFixtures.paused)
            == "Sandboxes: paused (1 job finishing, no new jobs); free slots Linux 0/1, macOS 0/1")
        #expect(line(SandboxFixtures.downloading) == "Sandboxes: downloading images (Linux 42%)")
        #expect(line(SandboxFixtures.waiting) == "Sandboxes: waiting for approval." + details)
        #expect(line(SandboxFixtures.error) == "Sandboxes: error." + details)
        #expect(line(SandboxFixtures.future) == "Sandboxes: hibernating." + details)
        #expect(SandboxStatusView.statusLine(.outdated)
            == "Sandboxes: installed; this add-on version reports no summary." + details)
        #expect(SandboxStatusView.statusLine(.unresponsive(seconds: 2))
            == "Sandboxes: installed; the add-on did not answer within 2s." + details)
        #expect(SandboxStatusView.statusLine(.failed("exit status 1: boom"))
            == "Sandboxes: installed; status unavailable (exit status 1: boom)." + details)
    }

    @Test("the not-installed JSON is a schema 1 document the CLI itself reads back")
    func notInstalledJSON() throws {
        let status = try #require(SandboxAddonStatus(json: Sandbox.notInstalledJSON))
        #expect(status.schema == 1 && !status.installed && status.state == .notInstalled)
        #expect(status.linux == .init(total: 0, free: 0) && status.jobsRunning == 0)
        #expect(SandboxStatusView.statusLine(.status(status, json: Sandbox.notInstalledJSON)) == nil)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(Sandbox.notInstalledJSON.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "installed", "version", "host_id", "state", "detail", "slots",
                                     "jobs_running", "images", "accepting", "last_update_check", "console_url"])
    }

    @Test("pause, resume and uninstall say what happens to running jobs")
    func actionMessages() {
        #expect(Sandbox.actionLines("pause", jobsRunning: 0) == [
            "Paused: this Mac takes no new sandbox jobs until you run `darkbloom sandbox resume`.",
            "  No jobs are running; inference serves as usual.",
        ])
        #expect(Sandbox.actionLines("pause", jobsRunning: 2)[1]
            == "  2 jobs still running; inference serves again once they end.")
        #expect(Sandbox.actionLines("resume", jobsRunning: 0)
            == ["Resumed: this Mac takes sandbox jobs again. Inference pauses while a job runs."])
        let consequences = Sandbox.Uninstall.consequences(root: "/Users/me/DarkbloomSandbox", jobsRunning: 1)
        #expect(consequences == [
            "This stops the Darkbloom Sandbox agent and removes /Users/me/DarkbloomSandbox: the app, its VM images and its state.",
            "  1 job running now will end and will not be paid. To let it finish, run `darkbloom sandbox pause` first.",
            "  Inference is not affected, and nothing pauses it for sandbox jobs any more.",
        ])
        #expect(Sandbox.Uninstall.consequences(root: "/r", jobsRunning: 0).count == 2)
    }

    @Test("logs tail the agent log, following renames with -F")
    func logsArguments() throws {
        #expect(Sandbox.Logs.tailArguments(path: "/r/agent/agent.log", lines: 50, follow: false)
            == ["-n", "50", "/r/agent/agent.log"])
        #expect(Sandbox.Logs.tailArguments(path: "/r/agent/agent.log", lines: 10, follow: true)
            == ["-F", "-n", "10", "/r/agent/agent.log"])
        let logs = try #require(try Darkbloom.parseAsRoot(["sandbox", "logs", "-f", "-n", "5"]) as? Sandbox.Logs)
        #expect(logs.follow && logs.lines == 5)
        #expect(try Sandbox.Logs.parse(["-l", "7"]).lines == 7)
        #expect(try Sandbox.Logs.parse([]).lines == 50)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["sandbox", "logs", "--lines", "-1"]) }
    }
}
