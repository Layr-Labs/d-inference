import Foundation

/// How the app locates a runnable `darkbloom` CLI binary.
protocol DarkbloomCLILocating: Sendable {
    func locate() -> URL?
}

/// Resolution order for the provider CLI the app shells out to:
///
///  1. `DARKBLOOM_CLI_PATH` — dev/test override.
///  2. `Contents/MacOS/darkbloom` inside this app's bundle — the release
///     layout, where the CLI ships beside the app binary.
///  3. `~/.darkbloom/bin/darkbloom` — the installer's canonical location.
///  4. `/usr/local/bin/darkbloom` and `/opt/homebrew/bin/darkbloom` — the
///     installer's PATH symlinks.
struct SystemDarkbloomCLILocator: DarkbloomCLILocating {
    static let environmentKey = "DARKBLOOM_CLI_PATH"

    let environment: [String: String]
    let bundleURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.environment = environment
        self.bundleURL = bundleURL
    }

    func locate() -> URL? {
        if let override = environment[Self.environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            bundleURL.appendingPathComponent("Contents/MacOS/darkbloom"),
            home.appendingPathComponent(".darkbloom/bin/darkbloom"),
            URL(fileURLWithPath: "/usr/local/bin/darkbloom"),
            URL(fileURLWithPath: "/opt/homebrew/bin/darkbloom"),
        ]
    }
}
