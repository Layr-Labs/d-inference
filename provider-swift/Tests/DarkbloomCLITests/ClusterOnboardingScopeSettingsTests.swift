import Testing
import ProviderCore
@testable import darkbloom

/// UNRUN: CLI parsing/settings binding only; no live onboarding or child starts. How `darkbloom cluster` was asked to
/// serve reaches the settings the guided setup plans with (`ClusterSetupOperations.LiveSettings.servingScope`):
/// `darkbloom cluster local` plans a local cluster, which keeps Qwen's speculative assistant, and plain
/// `darkbloom cluster` plans for the scope the setup record saved.
struct ClusterOnboardingScopeSettingsTests {
    @Test func theScopeAskedForReachesTheSettingsThePlanReads() throws {
        let local = try #require(try Darkbloom.parseAsRoot(["cluster", "local", "--bind", "127.0.0.1"]) as? Cluster.Local)
        let localLive = try Cluster.Setup.onboardingSettings(config: "/fixture/provider.toml", modelDir: nil, worker: nil,
            request: local.onboardingRequest)
        #expect(localLive.service.wizard.servingScope == .localOnly(bind: "127.0.0.1"))
        let plain = try Cluster.Setup.onboardingSettings(config: "/fixture/provider.toml", modelDir: nil, worker: nil,
            request: .init())
        #expect(plain.service.wizard.servingScope == nil)
        // The cluster service plans from the record (its re-plans after an update or a memory refusal), never from a run.
        let service = try Cluster.Setup.serviceSettings(config: "/fixture/provider.toml", modelDir: nil, worker: nil)
        #expect(service.wizard.servingScope == nil)
    }
}
