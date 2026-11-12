import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// The Darkbloom app runs the CLI (`DesktopBackend.arguments`). Each of its choices saves exactly one mode: Studio's
/// "Local only" saves Only me; "Alongside the network" and the app's setup save Both, me first. Its Start, Restart and
/// Update serve the saved mode and never change it, and login and the watchdog, which run the job as installed, serve
/// it too. Before, "Local only" saved no mode, so after the app's setup had saved Both, the app's own Restart and Update
/// put the Mac back on the Darkbloom network. Nothing here runs launchctl, binds a port or opens the Keychain.
@Suite("The app's choices save one mode; its Start, Restart and Update keep it")
struct AppServingChoiceTests {
    static let model = "fixture/model"
    static let binary = "/Applications/Darkbloom.app/Contents/MacOS/darkbloom"
    static let coordinator = "wss://coordinator.invalid/ws/provider"

    /// A Mac with `saved` in `[local]` (nil: a Mac updated from 0.10.10, which saved none) and the job the start that
    /// saved it installed.
    struct Mac {
        let config: TempConfig
        let job: JobPlist

        init(saved: LocalSettings.Mode?) throws {
            let local = saved.map { "\n[local]\nmode = \"\($0.rawValue)\"\n" + ($0 == .network ? "" : "port = 8003\n") }
            config = try TempConfig("[provider]\nname = \"app\"\n" + (local ?? ""))
            job = try JobPlist(["placeholder"])
            try install(saved ?? .network, port: 8003)
        }

        func remove() {
            config.remove()
            job.remove()
        }

        /// What the app's `action` runs (`DesktopBackend.arguments`), as the CLI's desktop API runs it.
        func argv(_ action: String, local: Bool? = nil, endpoint: Bool? = nil, models: Bool = true) throws -> [String] {
            var request = DesktopAction(id: UUID().uuidString, action: action)
            if models { request.models = [AppServingChoiceTests.model] }
            if action == "autopilot" { request.pinned = [] }
            request.local = local
            request.endpoint = endpoint
            return try DesktopBackend.arguments(for: request, configPath: config.path.path, localActive: false)
        }

        /// The job a start that serves `mode` installs (`launchOnlyMeService`, `launchDaemon`).
        func install(_ mode: LocalSettings.Mode, port: UInt16) throws {
            try job.write(mode == .local
                ? LaunchAgent.localProgramArguments(binaryPath: AppServingChoiceTests.binary,
                                                    models: [AppServingChoiceTests.model], configPath: config.path,
                                                    port: port, bind: "127.0.0.1", noAuth: false)
                : LaunchAgent.serviceProgramArguments(
                    binaryPath: AppServingChoiceTests.binary, coordinatorURL: AppServingChoiceTests.coordinator,
                    models: [AppServingChoiceTests.model], configPath: config.path,
                    localEndpoint: .init(enabled: mode == .both, port: port, bind: "127.0.0.1", noAuth: false)))
        }

        /// A start the app runs (`start …`, no terminal), and the job it installs.
        func start(_ argv: [String]) throws -> StartServing {
            let serving = try ScriptedTerminal().resolve(try Start.parse(Array(argv.dropFirst())))
            try install(serving.mode, port: serving.port)
            return serving
        }

        /// The app's Restart and Update run `restart` and `update`, which both end in `SavedChoiceService.restartAsSaved`:
        /// the job serves `mode` after them, nothing rewritten, and `[local]` is as it was. Login and the watchdog run the
        /// job as installed: it serves `mode` for them too.
        func expectRestartAndUpdateKeep(_ mode: LocalSettings.Mode, _ path: String) throws {
            for action in ["restart", "update"] {
                #expect(try argv(action, models: false) == [action, "--config", config.path.path], "\(path)")
                let before = (config: config.bytes, job: job.bytes)
                let aligned = try SavedChoiceService.align(configPath: config.path.path, plist: job.path,
                                                           thisMacPort: { _ in config.local?.port ?? 0 })
                #expect(aligned == SavedChoiceService.Alignment(mode: mode, line: nil), "\(path), then \(action)")
                #expect(job.bytes == before.job, "\(path), then \(action): the job as it was")
                #expect(config.bytes == before.config, "\(path), then \(action): nothing saved")
            }
            #expect(LaunchAgent.installedServingJob(at: job.path)?.mode == mode, "\(path): login and the watchdog")
        }
    }

    static func on(_ saved: LocalSettings.Mode?, _ body: (Mac) async throws -> Void) async throws {
        let mac = try Mac(saved: saved)
        defer { mac.remove() }
        try await body(mac)
    }

    @Test("each app path, for each saved mode: its choices save one mode; Start, Restart and Update keep the saved one",
          arguments: [LocalSettings.Mode?.none, .local, .network, .both])
    func appPaths(saved: LocalSettings.Mode?) async throws {
        let served = saved ?? .network
        // Restart and Update, on the job the saved mode's start installed.
        try await Self.on(saved) { mac in try mac.expectRestartAndUpdateKeep(served, "as saved") }

        // Start (the tray, Machines, Models): `start --model <id>` serves the saved mode and saves nothing; with none
        // saved, the default (Both, Darkbloom never paused), which is saved, so Restart and Update keep it from then on.
        try await Self.on(saved) { mac in
            let argv = try mac.argv("start")
            #expect(argv == ["start", "--model", Self.model, "--config", mac.config.path.path])
            let before = mac.config.bytes
            let serving = try mac.start(argv)
            if saved == nil {
                #expect(serving.mode == .both && serving.source == .default && !serving.meFirst, "Start")
                #expect(mac.config.local?.mode == .both && mac.config.local?.meFirst == false, "Start")
            } else {
                #expect(serving.mode == served && serving.change.isEmpty && mac.config.bytes == before, "Start")
            }
            try mac.expectRestartAndUpdateKeep(saved ?? .both, "Start")
        }

        // Studio's "Local only" (`desktop start-local`): Only me, saved, so Restart and Update keep it.
        try await Self.on(saved) { mac in
            let argv = try mac.argv("start", local: true)
            #expect(argv == ["desktop", "start-local", "--model", Self.model, "--config", mac.config.path.path])
            let command = try Desktop.StartLocal.parse(Array(argv.dropFirst(2)))
            let api = try Desktop.StartLocal.localAPI(configPath: command.configOptions.config, ownLivePort: { nil },
                                                       installedPort: { nil }, isFree: { _ in true })
            _ = try await Desktop.StartLocal.serve(api) { try mac.install(.local, port: api.choice.port) }
            #expect(mac.config.local?.mode == .local, "Local only")
            try mac.expectRestartAndUpdateKeep(.local, "Local only")
        }

        // The app's setup (its Autopilot, or a start with the models chosen) and Studio's "Alongside the network":
        // Both, me first, saved.
        for (path, action) in [("Alongside the network, and the setup's start", "start"), ("the setup's Autopilot", "autopilot")] {
            try await Self.on(saved) { mac in
                let argv = try mac.argv(action, local: action == "start" ? false : nil, endpoint: true)
                #expect(argv.contains("--local-endpoint"), "\(path)")
                let serving = try mac.start(argv)
                #expect(serving.mode == .both && mac.config.local?.mode == .both, "\(path)")
                try mac.expectRestartAndUpdateKeep(.both, path)
            }
        }
    }
}
