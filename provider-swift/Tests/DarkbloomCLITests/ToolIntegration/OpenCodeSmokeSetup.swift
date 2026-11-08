import Foundation
import Testing

@testable import darkbloom

/// The Darkbloom half of `scripts/integrations/opencode-smoke.sh`, which then runs the real OpenCode on the result.
///
/// It runs only when the script sets `DARKBLOOM_OPENCODE_SMOKE_HOME` to its throwaway home and
/// `DARKBLOOM_LOCAL_DIR` to the discovery folder inside it, where the script's fake server published `local.json`.
/// Through the real code it reads that endpoint, asks the fake server for its models with the key from the key file,
/// writes OpenCode's config into the throwaway home, and records the outcome in `smoke-result.json` there.
@Suite("OpenCode smoke setup")
struct OpenCodeSmokeSetup {
    @Test("writes OpenCode's config into the smoke script's throwaway home",
          .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_OPENCODE_SMOKE_HOME"] != nil))
    func writeTheConfig() async throws {
        let smokeHome = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_OPENCODE_SMOKE_HOME"])
        // Never anything of the real home: the throwaway home is a temp folder (the script passes its absolute,
        // resolved path), and every path below is inside it.
        let home = URL(fileURLWithPath: smokeHome, isDirectory: true)
        func isInside(_ url: URL) -> Bool { url.path.hasPrefix(home.path + "/") }
        let temporary = FileManager.default.temporaryDirectory.path
        let temporaryRoots = [temporary, "/private" + temporary, "/private/var/folders", "/private/tmp"]
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        try #require(!home.path.contains("/../") && temporaryRoots.contains { home.path.hasPrefix($0 + "/") })
        try #require(!home.path.hasPrefix(realHome + "/") && !realHome.hasPrefix(home.path))
        let localDirectory = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_LOCAL_DIR"])
        try #require(isInside(URL(fileURLWithPath: localDirectory)))

        // The script's fake server is no pair's part: this Mac's own cluster service isn't read.
        let endpoint = try #require(IntegrationEndpoint.live(pairPart: { nil }),
                                    "no live endpoint in \(localDirectory)/local.json")
        try #require(isInside(endpoint.keyFile))
        let models = IntegrationModels.resolve(try await IntegrationModels.fetch(endpoint), catalog: nil)
        let environment = ToolIntegrationEnvironment(
            home: home, variables: ["XDG_CONFIG_HOME": home.appendingPathComponent(".config").path])
        let file = IntegrationTool.opencode.configFile(in: environment)
        try #require(isInside(file) && isInside(environment.stateDirectory))

        let outcome = try ToolIntegration.configure(.opencode, endpoint: endpoint, models: models,
                                                    environment: environment)
        var result: [String: Any] = [
            "provider": IntegrationProvider.current.id,
            "models": models.map(\.id),
            "base_url": endpoint.baseURL,
            "file": file.path,
        ]
        switch outcome {
        case .written(_, let backup, let undo, let summary):
            result["outcome"] = "written"
            result["backup"] = backup?.path
            result["undo"] = undo
            result["default_model"] = summary.defaultModel
        case .unchanged:
            result["outcome"] = "unchanged"
        case .planned:
            result["outcome"] = "planned"
        case .refused(_, let refusal):
            result["outcome"] = "refused"
            result["reason"] = refusal.message(file: file.path)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: home.appendingPathComponent("smoke-result.json"))
    }
}
