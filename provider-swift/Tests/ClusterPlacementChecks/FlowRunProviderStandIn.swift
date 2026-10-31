import Foundation

// The provider pieces the placement step's run reads, for the plain-swiftc flow
// check: `Config/ProviderConfig.swift` needs TOMLKit, `SpecDec/` needs swift-log
// and `ClusterSetupModelFolders` lives with the setup wizard. The check runs
// with a private home that holds no provider configuration, so the step plans
// under the defaults (MTP `auto`), as `ConfigManager.loadOrDefaults` gives for
// a missing file. The embedded assistant's discovery reads the rest only for
// the registered Qwen3.8 27B, which this check does not plan: reaching it stops
// the check rather than inventing an answer.

enum MTPMode: String, Sendable, Equatable, Codable {
    case auto, on, off
}

struct ProviderConfig: Sendable {
    struct Backend: Sendable { var mtpMode = MTPMode.auto }
    var backend = Backend()
}

enum ConfigManager {
    static func defaultConfigPath() throws -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("provider.toml")
    }

    static func loadOrDefaults(from path: URL) throws -> ProviderConfig { ProviderConfig() }
}

enum SpecDecArtifactFunnel {
    /// The provider's process-wide kill switch, as `SpecDec/SpecDecArtifactFunnel.swift` reads it.
    static func killSwitchEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment["DARKBLOOM_CBV2_MTP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return true }
        return !["0", "false", "no", "off"].contains(raw)
    }
}

enum SpecDecStore {
    struct InlineDeclarationProbe { let mayDeclareEmbeddedArtifact: Bool }
    struct InlineArtifactRejection: Error {}

    static func inlineDeclarationProbe(directory: URL) -> InlineDeclarationProbe { notPlanned() }
    static func inspectInlineArtifact(directory: URL) -> Result<Void, InlineArtifactRejection> { notPlanned() }
}

enum ClusterSetupModelFolders {
    static func readManifest(_ url: URL) -> Data? { notPlanned() }
}

private func notPlanned(_ function: StaticString = #function) -> Never {
    preconditionFailure("\(function): the flow check plans no model with an embedded assistant")
}
