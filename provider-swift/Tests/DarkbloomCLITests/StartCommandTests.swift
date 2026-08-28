import ArgumentParser
import Darwin
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Serve runtime preparation (shared Start/Benchmark seam)")
struct StartCommandTests {
    @Test("TOML projection and metallib binding precede the first MLX touch")
    func projectionAndBindingPrecedeMetal() throws {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: false
        )
        var events: [String] = []

        let hash = try ServeRuntimePreparer.prepareRuntime(
            settings: settings,
            apply: { received in
                #expect(received.prefillLayer18 == false)
                #expect(received.weightedR1 == false)
                events.append("projection")
            },
            bindMetallib: {
                events.append("metallib")
                return "bound-hash"
            },
            requireMetal: {
                events.append("metal")
            }
        )

        #expect(hash == "bound-hash")
        #expect(events == ["projection", "metallib", "metal"])
    }

    @Test("a rejected projection aborts before the first MLX touch")
    func rejectedProjectionSkipsMetal() {
        var events: [String] = []
        let failure = GemmaOptimizationEnvironment.ApplicationFailure(
            keys: [
                GemmaOptimizationEnvironment.safeR1Key,
                GemmaOptimizationEnvironment.weightedUnsortKey,
            ],
            code: ENOMEM
        )

        // The coupled weighted-unsort/safe-R1 pair is a process-start latch:
        // a half-applied projection must reach neither metallib binding nor
        // engine construction.
        do {
            try ServeRuntimePreparer.prepareRuntime(
                settings: GemmaOptimizationSettings(),
                apply: { _ in
                    events.append("projection")
                    throw failure
                },
                bindMetallib: {
                    events.append("metallib")
                    return "must-not-bind"
                },
                requireMetal: {
                    events.append("metal")
                }
            )
            Issue.record("a rejected projection must abort serve preparation")
        } catch let error as GemmaOptimizationEnvironment.ApplicationFailure {
            #expect(error == failure)
            #expect("\(error)" == failure.description)
        } catch {
            Issue.record("expected ApplicationFailure, got \(error)")
        }

        #expect(events == ["projection"])
    }

    @Test("the default projection path is the environment apply boundary")
    func defaultApplyProjectsSettings() throws {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: true
        )
        let projection = GemmaOptimizationEnvironment.projection(for: settings)
        let saved = projection.keys.reduce(into: [String: String?]()) { out, key in
            out[key] = key.withCString { getenv($0).map { String(cString: $0) } }
        }
        defer {
            for (key, value) in saved {
                if let value {
                    _ = setenv(key, value, 1)
                } else {
                    _ = unsetenv(key)
                }
            }
        }
        var metalProbed = false

        try ServeRuntimePreparer.prepareRuntime(
            settings: settings,
            bindMetallib: { "test-bound-hash" },
            requireMetal: { metalProbed = true }
        )

        for (key, value) in projection {
            let observed = key.withCString { getenv($0).map { String(cString: $0) } }
            #expect(observed == value)
        }
        #expect(metalProbed)
    }

    @Test("the Start compatibility shim forwards the full startup order")
    func startShimForwards() throws {
        var events: [String] = []
        let hash = try Start.prepareServeRuntime(
            settings: GemmaOptimizationSettings(),
            apply: { _ in events.append("projection") },
            bindMetallib: {
                events.append("metallib")
                return "bound-hash"
            },
            requireMetal: { events.append("metal") }
        )
        #expect(hash == "bound-hash")
        #expect(events == ["projection", "metallib", "metal"])
    }

    @Test("benchmark env guard: a conflicting shell preset is rejected")
    func conflictingEnvironmentOverrideReportsConflict() throws {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: true,
            weightedR1: true
        )
        let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: settings
        ) { key in
            // Operator rolled back via the shell, config still selects on.
            key == GemmaOptimizationEnvironment.safeR1Key ? "0" : nil
        }

        let found = try #require(conflict)
        #expect(found.key == GemmaOptimizationEnvironment.safeR1Key)
        #expect(found.shellValue == "0")
        #expect(found.configValue == "trust")
    }

    @Test("benchmark env guard: the paired weighted-unsort key is checked too")
    func conflictingEnvironmentOverrideChecksWeightedKey() {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: false
        )
        let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: settings
        ) { key in
            key == GemmaOptimizationEnvironment.weightedUnsortKey ? "1" : nil
        }

        #expect(conflict?.key == GemmaOptimizationEnvironment.weightedUnsortKey)
        #expect(conflict?.shellValue == "1")
        #expect(conflict?.configValue == "0")
    }

    @Test("benchmark env guard: matching or unset shell values are not flagged")
    func conflictingEnvironmentOverrideAllowsConsistent() {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: true,
            weightedR1: false
        )
        let projection = GemmaOptimizationEnvironment.projection(for: settings)

        // Every preset value EQUALS the projection — consistent, proceed.
        let consistent = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: settings
        ) { projection[$0] }
        #expect(consistent == nil)

        // Nothing preset at all — proceed.
        let unset = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: settings
        ) { _ in nil }
        #expect(unset == nil)
    }

    @Test("benchmark env guard: a trust shell export is not a conflict when the route is on")
    func conflictingEnvironmentOverrideAcceptsTrust() {
        // Serving defaults to trust, so an explicit trust export matches.
        let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: GemmaOptimizationSettings(
                prefillLayer18: true,
                weightedR1: true
            )
        ) { key in
            key == GemmaOptimizationEnvironment.safeR1Key ? "trust" : nil
        }
        #expect(conflict == nil)
    }

    @Test("benchmark env guard: a drain shell export is not a conflict when the route is on")
    func conflictingEnvironmentOverrideAcceptsDrain() {
        // Exact MLX_GATHER_QMM_EXPERT_SLICES=1 is the serving escape hatch;
        // the guard must not refuse the drain-mode benchmark.
        let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: GemmaOptimizationSettings(
                prefillLayer18: true,
                weightedR1: true
            )
        ) { key in
            key == GemmaOptimizationEnvironment.safeR1Key ? "1" : nil
        }
        #expect(conflict == nil)
    }

    @Test("benchmark env guard: trust against a config-OFF route is a conflict")
    func conflictingEnvironmentOverrideRejectsTrustWhenRouteOff() throws {
        let conflict = ServeRuntimePreparer.conflictingEnvironmentOverride(
            settings: GemmaOptimizationSettings(
                prefillLayer18: true,
                weightedR1: false
            )
        ) { key in
            key == GemmaOptimizationEnvironment.safeR1Key ? "trust" : nil
        }
        let found = try #require(conflict)
        #expect(found.key == GemmaOptimizationEnvironment.safeR1Key)
        #expect(found.shellValue == "trust")
        #expect(found.configValue == "0")
    }

    @Test("start accepts an explicit custom config")
    func customConfigParses() throws {
        let parsed = try Darkbloom.parseAsRoot([
            "start", "--config", "/tmp/custom provider.toml", "--foreground",
        ])
        let command = try #require(parsed as? Start)
        #expect(command.configOptions.config == "/tmp/custom provider.toml")
    }
}
