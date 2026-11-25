import Foundation
import Testing
@testable import ProviderBuildEnvironment
@testable import ProviderCore

/// The variables that move the provider's state files and its model mirror: a
/// release build keeps the install directory's files and the build's CDN
/// whatever the environment says; a debug build reads them; a location the
/// process assigned wins in both. No file is read or written.
@Suite struct LocationOverrideTests {
    static let elsewhere = "/tmp/darkbloom-location-override-test/elsewhere"

    static func environment(_ location: LocationOverride, _ value: String = elsewhere) -> [String: String] {
        [location.environmentKey: value]
    }

    @Test func releaseBuildsIgnoreEveryVariable() {
        for location in LocationOverride.allCases {
            #expect(location.value(environment: Self.environment(location), readsEnvironment: false, assigned: [:]) == nil,
                    "\(location.environmentKey)")
        }
    }

    @Test func debugBuildsReadNonEmptyVariables() {
        for location in LocationOverride.allCases {
            #expect(location.value(environment: Self.environment(location), readsEnvironment: true, assigned: [:])
                    == Self.elsewhere)
            #expect(location.value(environment: Self.environment(location, ""), readsEnvironment: true, assigned: [:]) == nil)
        }
    }

    @Test func anAssignedLocationWinsInEveryBuild() {
        for location in LocationOverride.allCases {
            for reads in [false, true] {
                #expect(location.value(environment: Self.environment(location), readsEnvironment: reads,
                                       assigned: [location: "/assigned"]) == "/assigned")
            }
        }
    }

    @Test func releaseBuildFilesStayInTheInstallDirectory() {
        let install = BuildEnvironment.current.installDirectory()
        LocationOverride.$readsEnvironmentForTesting.withValue(false) {
            // The ambient environment may set these (scripts/run-provider-tests.sh does); a release build ignores it.
            #expect(DaemonStateFile.path() == install.appendingPathComponent("daemon-state.json"))
            #expect(LoadedModelsStore.path() == install.appendingPathComponent("loaded-models.json"))
            #expect(VerifiedWeightHashStore.path() == install.appendingPathComponent("verified-weights.json"))
            #expect(ProcessLifecycle.defaultPIDFile() == install.appendingPathComponent("provider.pid"))
            #expect(WatchdogStateStore.path() == install.appendingPathComponent("watchdog-state.json"))
            #expect(AuthTokenStore.tokenPath() == install.appendingPathComponent("auth_token"))
            #expect(LocalEndpoint.directory() == install)
            #expect(KVBackendGuardStore.path(environment: Self.environment(.kvBackendGuard))
                    == install.appendingPathComponent("kv-backend-guard.json"))
            #expect(ModelDownloader.resolveCDNURL(environment: Self.environment(.modelCDN, "https://mirror.example"))
                    == ModelDownloader.defaultR2CDNURL)
        }
    }

    @Test func debugBuildsFollowTheVariables() {
        LocationOverride.$readsEnvironmentForTesting.withValue(true) {
            #expect(KVBackendGuardStore.path(environment: Self.environment(.kvBackendGuard)).path == Self.elsewhere)
            #expect(ModelDownloader.resolveCDNURL(environment: Self.environment(.modelCDN, "https://mirror.example/"))
                    == "https://mirror.example")
        }
    }

    @Test func anExplicitMirrorStillWins() {
        for reads in [false, true] {
            LocationOverride.$readsEnvironmentForTesting.withValue(reads) {
                #expect(ModelDownloader.resolveCDNURL(explicit: "https://explicit.example/",
                                                      environment: Self.environment(.modelCDN, "https://mirror.example"))
                        == "https://explicit.example")
            }
        }
    }

    @Test func thisBuildReadsTheVariablesOnlyWhenItIsADebugBuild() {
        LocationOverride.$readsEnvironmentForTesting.withValue(nil) {
            #if DEBUG
            #expect(LocationOverride.readsEnvironmentInThisBuild)
            #else
            #expect(!LocationOverride.readsEnvironmentInThisBuild)
            #endif
        }
    }
}
