import ArgumentParser
import Testing
import ProviderCore
@testable import darkbloom

/// UNRUN: CLI parsing/settings binding only; no live onboarding or child starts.
struct MiMoImageOnboardingCommandTests {
    @Test func privateFlagReachesTheActualLiveSettingsWithoutChangingChildRoutes() throws {
        let command = try #require(try Darkbloom.parseAsRoot(["cluster", "local", ClusterOnboardingRequest.privateMiMoModelID,
            "--private-mimo-image-qualification", "--bind", "127.0.0.1"]) as? Cluster.Local)
        #expect(command.privateMiMoImageQualification)
        #expect(command.onboardingRequest.privateMiMoImageQualification)
        let live = try Cluster.Setup.onboardingSettings(config: "/fixture/provider.toml", modelDir: nil, worker: nil,
            request: command.onboardingRequest)
        #expect(live.service.wizard.privateMiMoImageQualification)
        #expect(live.service.leaderArguments == ["start", "--local", "--distributed", "--config", "/fixture/provider.toml"])
        #expect(live.service.followerArguments == ["cluster", "link-follower", "--config", "/fixture/provider.toml"])
        #expect(live.serviceArguments == ["cluster", "service", "--config", "/fixture/provider.toml"])
    }
    @Test func ordinaryLocalAndPublicSetupKeepTheirExistingSelection() throws {
        let ordinary = try Cluster.Local.parse([ClusterOnboardingRequest.privateMiMoModelID])
        #expect(!ordinary.onboardingRequest.privateMiMoImageQualification)
        let live = try Cluster.Setup.onboardingSettings(config: "/fixture/provider.toml", modelDir: nil, worker: nil,
            request: ordinary.onboardingRequest)
        #expect(!live.service.wizard.privateMiMoImageQualification)
        #expect(throws: (any Error).self) { _ = try Cluster.Setup.parse(["--private-mimo-image-qualification"]) }
        #expect(throws: (any Error).self) { _ = try Cluster.Local.parse(["--runtime-profile", "arbitrary"]) }
    }
    @Test func missingOrForeignModelCannotBecomeTheCandidate() {
        for args in [["--private-mimo-image-qualification"], ["glm-5-next", "--private-mimo-image-qualification"],
                     ["mimo-v2.6-flash-mopd-other", "--private-mimo-image-qualification"]] {
            #expect(throws: (any Error).self) { _ = try Cluster.Local.parse(args) }
        }
    }
}
