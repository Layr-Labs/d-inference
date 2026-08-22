import ArgumentParser
import Foundation
import ProviderCore

// Entry point. The long-running serve modes (start --foreground / --local) are
// hosted under an NSApplication(.accessory) run loop so the process can
// registerForRemoteNotifications() and answer APNs code-identity challenges
// (v0.6.0). Everything else runs through the normal ArgumentParser async
// dispatch. The @main AsyncParsableCommand main-task drain is mutually exclusive
// with the AppKit event loop, which is exactly why the serve path is dispatched
// here instead of via @main on Darkbloom.

let rawArgs = Array(CommandLine.arguments.dropFirst())

// An installed pre-v0.8.10 updater cannot seed the new packaged-smoke latch
// environment. Bootstrap it in the candidate itself before command parsing or
// AppKit hosting can cause a first MLX/Metal touch.
if rawArgs.first == "runtime-smoke" {
    do {
        try PackagedRuntimeSmoke.seedRetainedValidationEnvironment()
    } catch {
        Darkbloom.exit(withError: error)
    }
}

#if os(macOS)
if ProviderAppKitHost.shouldHost(rawArgs) {
    // Takes over the main thread with the AppKit run loop and never returns.
    ProviderAppKitHost.runHosted(rawArgs)
}
#endif

// Non-serve path: parse + dispatch as ArgumentParser's async main() would, done
// manually because @main is removed (it would fight AppKit for the main thread).
do {
    var command = try Darkbloom.parseAsRoot(rawArgs)
    if var asyncCommand = command as? any AsyncParsableCommand {
        try await runAsyncCommand(&asyncCommand)
    } else {
        try command.run()
    }
} catch {
    Darkbloom.exit(withError: error)
}

// The helper boundary is load-bearing: at top-level scope a bare
// `asyncCommand.run()` binds to the synchronous ParsableCommand witness, whose
// AsyncParsableCommand default throws a help request — so every subcommand printed
// help instead of running (#286). Routing through `inout any AsyncParsableCommand`
// forces the async witness. Covered by CLIDispatchTests.
func runAsyncCommand(_ command: inout any AsyncParsableCommand) async throws {
    try await command.run()
}
