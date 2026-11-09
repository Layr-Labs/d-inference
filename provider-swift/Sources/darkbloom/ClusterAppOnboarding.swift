import Foundation
import ArgumentParser
import ProviderCore

extension Cluster.Setup {
    /// `darkbloom cluster --app-console` and `darkbloom cluster local --app-console`: the onboarding for the desktop app's
    /// guided setup (`DesktopClusterSession`), with no terminal. Its screens are JSON lines on standard output and its
    /// answers JSON lines on standard input (`ClusterOnboardingAppConsole`); the flow, its operations, the waitlist gate
    /// and the console lock are the terminal's. The last line is `{"event":"exit","code":N}`, N the exit status.
    static func runAppOnboarding(config: String?, modelDir: String?, worker: String?, request: ClusterOnboardingRequest,
                                 needsTerminal: String) async throws {
        guard let console = ClusterOnboardingAppConsole.standardStreams(needsTerminal: needsTerminal) else {
            printError("Can't open the setup's console: its standard input and output can't be copied.")
            throw ExitCode.failure
        }
        Darkbloom.ensureLogging()
        var code: Int32 = 1
        defer { console.finish(code) }
        do {
            try await requireNewPairApproval(request: request, gate: appWaitlistGate(console: console, access: .live(configPath: config)))
            let settings = try onboardingSettings(config: config, modelDir: modelDir, worker: worker, request: request)
            let operations = forApp(withServingChoice(try ClusterOnboardingOperations.live(settings), config: config, request: request))
            let instance = try ClusterConsoleInstanceLock.acquire()
            code = await Task.detached { ClusterOnboardingDriver.run(operations, console: console, request: request) }.value
            withExtendedLifetime(instance) {}
        } catch let exit as ExitCode {
            code = exit.rawValue
            throw exit
        } catch {
            // Said on the app's screen; the setup ends as a terminal's would, with nothing more asked.
            console.say(String(describing: error))
            throw ExitCode.failure
        }
        if code != 0 { throw ExitCode(code) }
    }

    /// The clusters waitlist gate on the app's console: its lines are said, and its question ("Join the Clusters waitlist
    /// now?") is said and answered from a list, No first, as the terminal's `[y/N]`.
    static func appWaitlistGate(console: ClusterOnboardingConsole, access: @escaping @autoclosure () -> FeatureWaitlistAccess)
        -> () -> FeatureWaitlistGate {
        {
            var gate = clusterWaitlistGate(access: access())()
            gate.ask = { question in
                console.say(question)
                return console.choose(appWaitlistAnswers, selected: 1) == 0
            }
            gate.say = { console.say($0) }
            gate.warn = { console.say($0) }
            return gate
        }
    }

    /// The waitlist question's answers on the app's console.
    static let appWaitlistAnswers = ["Yes", "No"]

    /// The live operations as the app's console runs them. Local Network's prompt names Darkbloom: the desktop API runs
    /// this setup, never a terminal app. "Log in on this Mac" reads the login this Mac has now: `darkbloom login` would
    /// wait for a code no app screen shows, so the app's own sign-in (or `darkbloom login` in Terminal) logs this Mac in
    /// and the choice then goes on.
    static func forApp(_ live: ClusterOnboardingOperations) -> ClusterOnboardingOperations {
        var operations = live
        operations.commandApp = { ClusterOnboardingCommand.app }
        operations.login = { AuthTokenStore.load() != nil }
        return operations
    }
}
