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

#if os(macOS)
if ProviderAppKitHost.shouldHost(rawArgs) {
    // Takes over the main thread with the AppKit run loop and never returns.
    ProviderAppKitHost.runHosted(rawArgs)
}
#endif

// Non-serve path: parse + run exactly as ArgumentParser's async main() would.
// Done manually (not via Darkbloom.main()) because, without @main, the sync
// main() overload fatals on an async root command.
do {
    var command = try Darkbloom.parseAsRoot(rawArgs)
    if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
    } else {
        try command.run()
    }
} catch {
    Darkbloom.exit(withError: error)
}
