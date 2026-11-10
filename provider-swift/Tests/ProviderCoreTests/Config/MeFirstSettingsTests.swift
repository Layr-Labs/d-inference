import Foundation
import Testing

@testable import ProviderCore

/// Where me first applies (`LocalSettings.meFirstIdle`, `ProviderLoopConfig.meFirstIdle`): only where Darkbloom and
/// the owner share this Mac, a coordinator connection with the local API beside it, unless `[local]` turns it off.
@Suite("Me first: where it applies")
struct MeFirstSettingsTests {
    static let twoMinutes = Duration.seconds(120)

    @Test func theLocalAPIBesideTheCoordinatorPausesForTheOwnerUntilTwoIdleMinutesByDefault() {
        // `--local-endpoint` without a `[local]` section: Both, me first.
        #expect(LocalSettings().meFirstIdle(local: false, localEndpoint: true) == Self.twoMinutes)
        #expect(LocalSettings(mode: .both).meFirstIdle(local: false, localEndpoint: true) == Self.twoMinutes)
        #expect(LocalSettings(meFirst: true).meFirstIdle(local: false, localEndpoint: true) == Self.twoMinutes)
        #expect(LocalSettings(meFirstIdleMinutes: 1).meFirstIdle(local: false, localEndpoint: true) == .seconds(60))
        #expect(LocalSettings(meFirstIdleMinutes: 10).meFirstIdle(local: false, localEndpoint: true) == .seconds(600))
        #expect(LocalSettings(meFirstIdleMinutes: 120).meFirstIdle(local: false, localEndpoint: true) == .seconds(7_200))
    }

    @Test func meFirstFalseKeepsTodaysSharedServing() {
        #expect(LocalSettings(meFirst: false).meFirstIdle(local: false, localEndpoint: true) == nil)
        #expect(LocalSettings(mode: .both, meFirst: false, meFirstIdleMinutes: 5)
            .meFirstIdle(local: false, localEndpoint: true) == nil)
    }

    /// `--local`: the standalone server, which never connects to a coordinator, so there is nothing to pause.
    @Test(arguments: [
        LocalSettings(), LocalSettings(mode: .both), LocalSettings(mode: .both, meFirst: true, meFirstIdleMinutes: 5),
        LocalSettings(mode: .local, meFirst: true),
    ])
    func withoutACoordinatorNothingPauses(_ settings: LocalSettings) {
        #expect(settings.meFirstIdle(local: true, localEndpoint: true) == nil)
        #expect(settings.meFirstIdle(local: true, localEndpoint: false) == nil)
    }

    @Test func withoutTheLocalAPIOrOutsideBothThereIsNoOwnerUse() {
        // Plain `start`: Darkbloom only, with no local API to use.
        #expect(LocalSettings().meFirstIdle(local: false, localEndpoint: false) == nil)
        #expect(LocalSettings(mode: .both, meFirst: true).meFirstIdle(local: false, localEndpoint: false) == nil)
        // A saved mode other than both wins over the launch flags (`resolvedMode`).
        #expect(LocalSettings(mode: .network).meFirstIdle(local: false, localEndpoint: true) == nil)
        #expect(LocalSettings(mode: .local, meFirst: true).meFirstIdle(local: false, localEndpoint: true) == nil)
    }

    @Test func aProviderLoopTakesItsSettingsFromTheLoadedConfig() {
        func loopConfig(_ local: LocalSettings?, endpoint: Bool) -> ProviderLoopConfig {
            ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/ignored", hardware: ModelLoadingFixtures.defaultHardware, models: [],
                config: ProviderConfig(provider: ProviderSettings(name: "me-first-settings-test"), local: local),
                localEndpoint: endpoint ? LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0) : nil)
        }
        #expect(loopConfig(nil, endpoint: true).meFirstIdle == Self.twoMinutes)
        #expect(loopConfig(LocalSettings(meFirstIdleMinutes: 5), endpoint: true).meFirstIdle == .seconds(300))
        #expect(loopConfig(LocalSettings(meFirst: false), endpoint: true).meFirstIdle == nil)
        #expect(loopConfig(nil, endpoint: false).meFirstIdle == nil)
        #expect(loopConfig(LocalSettings(mode: .both, meFirst: true), endpoint: false).meFirstIdle == nil)
    }
}
