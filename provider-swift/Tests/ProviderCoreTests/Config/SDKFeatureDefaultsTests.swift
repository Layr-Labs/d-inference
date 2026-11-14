import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("SDK feature defaults")
struct SDKFeatureDefaultsTests {
    @Test func listedSwitchesTurnOnOnlyWhereTheOperatorSetNothing() {
        let keys = ["DARKBLOOM_A", "DARKBLOOM_B", "DARKBLOOM_C"]
        // The operator's non-empty value always wins: `0` is the kill switch,
        // and any explicit spelling is left exactly as given.
        let projection = SDKFeatureDefaults.projection(
            onByDefault: keys, environment: ["DARKBLOOM_B": "0", "DARKBLOOM_C": "off", "UNRELATED": "x"])
        #expect(projection == ["DARKBLOOM_A": "1"])
        // Empty means unset, as for the LaunchAgent, which drops empty values:
        // foreground and installed service agree.
        #expect(SDKFeatureDefaults.projection(onByDefault: keys, environment: ["DARKBLOOM_A": ""]).keys.sorted()
            == keys)
        #expect(SDKFeatureDefaults.projection(onByDefault: [], environment: [:]).isEmpty)
    }

    @Test func injectedDefaultsAreNeverWrittenIntoAServicePlist() {
        // review prov-2109 SF1: an installing `darkbloom` process carries its own
        // injected defaults; persisting them would pin today's default into the
        // plist, so a later release could not change it without a reinstall.
        let key = "DARKBLOOM_GEMMA_SCHEMA_COERCION"
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"], injected: [key]).isEmpty)
        // The operator's own value (not injected) is still forwarded, `0` included.
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"], injected: []) == [key: "0"])
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"], injected: []) == [key: "1"])
    }

    @Test func everyDefaultOnSwitchReachesTheInstalledService() {
        // A default-ON switch is only a kill switch if the LaunchAgent forwards it.
        let perBuild = [SDKFeatureDefaults.constraintSpansKey, SDKFeatureDefaults.grammarMTPKey,
                        NativeReasoningBudget.environmentKey]
        for key in SDKFeatureDefaults.onByDefault + perBuild {
            #expect(LaunchAgent.passthroughEnvKeys.contains(key), "\(key)")
        }
        // The per-build MTP switches are never set process-wide: the SDK's
        // `CBv2MTPConfig` would read an injected `1` on every model.
        #expect(!SDKFeatureDefaults.onByDefault.contains(SDKFeatureDefaults.constraintSpansKey))
        #expect(!SDKFeatureDefaults.onByDefault.contains(SDKFeatureDefaults.grammarMTPKey))
    }

    /// The environment a `darkbloom` child inherits after its parent's `apply`.
    private func inherited(_ environment: [String: String], _ plan: SDKFeatureDefaults.Plan) -> [String: String] {
        var child = environment.merging(plan.set) { $1 }
        for key in plan.unset { child[key] = nil }
        return child
    }

    @Test func aDarkbloomChildNeverPersistsItsParentsInjectedDefaults() {
        // review prov-2109-d2 MUST-FIX 1: `darkbloom desktop serve` injects a
        // default, its DesktopWorker child (`start`, `desktop start-local`)
        // inherits KEY=1 and installs the provider plist. The child must still
        // know KEY=1 is the release's, not the operator's.
        let key = "DARKBLOOM_GEMMA_SCHEMA_COERCION"
        let marker = SDKFeatureDefaults.injectedMarkerKey
        let operatorEnvironment = ["HOME": "/Users/op", "DARKBLOOM_OTHER": "x"]
        let parent = SDKFeatureDefaults.plan(onByDefault: [key], environment: operatorEnvironment)
        #expect(parent.injected == [key])
        let childEnvironment = inherited(operatorEnvironment, parent)
        #expect(childEnvironment[key] == "1")
        let child = SDKFeatureDefaults.plan(onByDefault: [key], environment: childEnvironment)
        #expect(child.injected == [key])
        let childAfter = inherited(childEnvironment, child)
        let plist = LaunchAgent.passthroughEnvironment(from: childAfter, injected: Set(child.injected))
        #expect(plist[key] == nil)
        #expect(plist[marker] == nil)
        // A grandchild still knows.
        let grandchild = SDKFeatureDefaults.plan(onByDefault: [key], environment: childAfter)
        #expect(grandchild.injected == [key])
    }

    @Test func aChildFollowsItsOwnReleaseAndTheOperator() {
        let key = "DARKBLOOM_GEMMA_SCHEMA_COERCION"
        let marker = SDKFeatureDefaults.injectedMarkerKey
        // A child of a newer release that no longer lists the key restores the
        // SDK default instead of keeping its parent's injection.
        let dropped = SDKFeatureDefaults.plan(onByDefault: [], environment: [key: "1", marker: key])
        #expect(dropped.injected.isEmpty)
        #expect(Set(dropped.unset) == [key, marker])
        // The operator's value in the child's own environment wins (`0` kills),
        // even beside a stale marker.
        let killed = SDKFeatureDefaults.plan(onByDefault: [key], environment: [key: "0", marker: key])
        #expect(killed.injected.isEmpty)
        #expect(killed.set[key] == nil)
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0", marker: key], injected: [])[key] == "0")
    }

    @Test func theMarkerIsNeverForwarded() {
        let marker = SDKFeatureDefaults.injectedMarkerKey
        #expect(!LaunchAgent.passthroughEnvKeys.contains(marker))
        #expect(LaunchAgent.passthroughEnvironment(from: [marker: "DARKBLOOM_X"], injected: [])[marker] == nil)
    }

    @Test func mtpDefaultsTurnOnOnlyForListedBuildsAndOnlyWhenUnset() {
        // review prov-2109-d2 SF3: a default is on only where it was measured.
        let builds: Set<String> = ["qwen3.8-27b"]
        func config(spans: Bool = false, grammar: Bool = false, modelId: String, modelType: String?,
                    environment: [String: String] = [:]) -> CBv2MTPConfig {
            var config = CBv2MTPConfig(enabled: true, constrainedSpeculation: grammar, freeSpanSpeculation: spans)
            SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: modelId, modelType: modelType,
                environment: environment, spansBuilds: builds, grammarBuilds: builds)
            return config
        }
        let qwen38 = config(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5")
        #expect(qwen38.freeSpanSpeculation && qwen38.constrainedSpeculation)
        for (id, type) in [("gemma-4-26b-qat-4bit", "gemma4"), ("mlx-community/Qwen3.6-35B-A3B-4bit", "qwen3_5_moe"),
                           ("mlx-community/Qwen3.5-9B-MLX-4bit", "qwen3_5")] {
            let other = config(modelId: id, modelType: type)
            #expect(!other.freeSpanSpeculation && !other.constrainedSpeculation, "\(id)")
        }
        // The operator's value is the SDK's reading (here: the config as built):
        // `0` keeps the listed build off, `1` turns any build on.
        let killed = config(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
            environment: [SDKFeatureDefaults.constraintSpansKey: "0", SDKFeatureDefaults.grammarMTPKey: "off"])
        #expect(!killed.freeSpanSpeculation && !killed.constrainedSpeculation)
        let optedIn = config(spans: true, grammar: true, modelId: "gemma-4-26b-qat-4bit", modelType: "gemma4",
            environment: [SDKFeatureDefaults.constraintSpansKey: "1", SDKFeatureDefaults.grammarMTPKey: "1"])
        #expect(optedIn.freeSpanSpeculation && optedIn.constrainedSpeculation)
        // Empty is unset, as everywhere else.
        let empty = config(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
            environment: [SDKFeatureDefaults.constraintSpansKey: "", SDKFeatureDefaults.grammarMTPKey: ""])
        #expect(empty.freeSpanSpeculation && empty.constrainedSpeculation)
    }

    @Test func reasoningBudgetsFollowTheFamilyDefaultUnlessTheOperatorSetsThem() {
        let key = NativeReasoningBudget.environmentKey
        func on(_ family: NativeReasoningBudget.Family, _ environment: [String: String],
                injected: Set<String> = []) -> Bool {
            NativeReasoningBudget.isEnabled(for: family, environment: environment,
                families: [.nemotronSuper], injected: injected)
        }
        #expect(on(.nemotronSuper, [:]))
        #expect(!on(.mimoV26, [:]))
        // The release's own `1` (injected so engines accept budget rows) is not
        // the operator's: MiMo stays off.
        #expect(!on(.mimoV26, [key: "1"], injected: [key]))
        #expect(on(.nemotronSuper, [key: "1"], injected: [key]))
        // The operator's value applies to every family.
        #expect(on(.mimoV26, [key: "1"]))
        #expect(!on(.nemotronSuper, [key: "0"]))
        #expect(on(.nemotronSuper, [key: ""]))
    }

    @Test func theSlotFactoryAppliesThePerBuildDefaults() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent(
            "ProviderCore/Inference/Engine/Factory/EngineV2SlotFactory.swift"), encoding: .utf8)
            .filter { !$0.isWhitespace }
        #expect(source.contains("SDKFeatureDefaults.applyMTPDefaults(to:&mtpConfig,modelId:modelId,modelType:modelType"))
    }

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Config
        .deletingLastPathComponent()  // ProviderCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // provider-swift
        .appendingPathComponent("Sources")
}
