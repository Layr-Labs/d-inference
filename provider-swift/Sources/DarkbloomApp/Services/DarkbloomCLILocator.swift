import Foundation
import ProviderCoreFoundation

/// How the app locates a runnable `darkbloom` CLI binary.
protocol DarkbloomCLILocating: Sendable {
    func locate() -> URL?
}

/// Resolution order for the provider CLI the app shells out to:
///
///  1. `DARKBLOOM_CLI_PATH` — debug/test override, compiled out of release
///     builds.
///  2. `~/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom` — the only
///     shipping candidate.
///
/// The GUI must invoke the managed bundle directly. Falling back to the
/// currently-running bundle or a PATH symlink can make `darkbloom start`
/// persist a LaunchAgent whose executable points into Downloads or another
/// replaceable location.
struct SystemDarkbloomCLILocator: DarkbloomCLILocating {
    static let environmentKey = "DARKBLOOM_CLI_PATH"

    let environment: [String: String]
    let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func locate() -> URL? {
        #if DEBUG
        if let override = environment[Self.environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif

        return ManagedCLIPathValidator().validatedCLIURL(
            homeDirectory: homeDirectory
        )
    }

    var managedCLIURL: URL {
        ManagedProviderInstallLayout.cliURL(homeDirectory: homeDirectory)
    }
}
