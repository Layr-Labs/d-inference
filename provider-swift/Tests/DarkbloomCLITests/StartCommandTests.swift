import ArgumentParser
import Darwin
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Start command runtime preparation")
struct StartCommandTests {
    @Test("TOML projection precedes the first MLX touch")
    func projectionPrecedesMetal() throws {
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: false
        )
        var events: [String] = []

        try Start.prepareServeRuntime(
            settings: settings,
            apply: { received in
                #expect(received.prefillLayer18 == false)
                #expect(received.weightedR1 == false)
                events.append("projection")
            },
            requireMetal: {
                events.append("metal")
            }
        )

        #expect(events == ["projection", "metal"])
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
        // a half-applied projection must never reach engine construction.
        do {
            try Start.prepareServeRuntime(
                settings: GemmaOptimizationSettings(),
                apply: { _ in
                    events.append("projection")
                    throw failure
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

        try Start.prepareServeRuntime(
            settings: settings,
            requireMetal: { metalProbed = true }
        )

        for (key, value) in projection {
            let observed = key.withCString { getenv($0).map { String(cString: $0) } }
            #expect(observed == value)
        }
        #expect(metalProbed)
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
