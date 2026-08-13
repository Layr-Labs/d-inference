import Darwin
import Testing
@testable import ProviderCore

@Suite("Gemma optimization config")
struct GemmaOptimizationConfigTests {
    @Test("missing optimization section enables the selected stack")
    func missingSectionDefaultsOn() {
        let config = ConfigManager.parse("""
            [provider]
            name = "test-provider"
            """)

        #expect(config.gemmaOptimizations == GemmaOptimizationSettings())
        #expect(config.gemmaOptimizations.prefillLayer18)
        #expect(config.gemmaOptimizations.weightedR1)
    }

    @Test("partial optimization section defaults each missing key on")
    func partialSectionDefaultsMissingKeysOn() {
        let layerOnly = ConfigManager.parse("""
            [provider]
            name = "test-provider"

            [gemma_optimizations]
            prefill_layer18 = false
            """)
        #expect(!layerOnly.gemmaOptimizations.prefillLayer18)
        #expect(layerOnly.gemmaOptimizations.weightedR1)

        let weightedOnly = ConfigManager.parse("""
            [provider]
            name = "test-provider"

            [gemma_optimizations]
            weighted_r1 = false
            """)
        #expect(weightedOnly.gemmaOptimizations.prefillLayer18)
        #expect(!weightedOnly.gemmaOptimizations.weightedR1)
    }

    @Test("explicit optimization values are honored")
    func explicitValues() {
        let config = ConfigManager.parse("""
            [provider]
            name = "test-provider"

            [gemma_optimizations]
            prefill_layer18 = false
            weighted_r1 = false
            """)

        #expect(!config.gemmaOptimizations.prefillLayer18)
        #expect(!config.gemmaOptimizations.weightedR1)
    }

    @Test("optimization settings round trip with snake-case TOML keys")
    func snakeCaseRoundTrip() {
        let original = ProviderConfig(
            provider: ProviderSettings(name: "test-provider"),
            gemmaOptimizations: GemmaOptimizationSettings(
                prefillLayer18: false,
                weightedR1: true
            )
        )

        let toml = ConfigManager.serialize(original)
        let decoded = ConfigManager.parse(toml)

        #expect(toml.contains("[gemma_optimizations]"))
        #expect(toml.contains("prefill_layer18 = false"))
        #expect(toml.contains("weighted_r1 = true"))
        #expect(!toml.contains("gemmaOptimizations"))
        #expect(!toml.contains("prefillLayer18"))
        #expect(!toml.contains("weightedR1"))
        #expect(decoded == original)
    }
}

@Suite("Gemma optimization environment")
struct GemmaOptimizationEnvironmentTests {
    private let expectedKeys: Set<String> = [
        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL",
        "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT",
        "MLX_GATHER_QMM_EXPERT_SLICES",
    ]

    @Test("projection emits exactly the three selected controls")
    func exactProjection() {
        let enabled = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings()
        )
        #expect(enabled == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "18",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
            "MLX_GATHER_QMM_EXPERT_SLICES": "1",
        ])

        let disabled = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(
                prefillLayer18: false,
                weightedR1: false
            )
        )
        #expect(disabled == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "0",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "0",
            "MLX_GATHER_QMM_EXPERT_SLICES": "0",
        ])
    }

    @Test("weighted unsort and safe R1 are atomic in every projection")
    func weightedR1IsAtomic() {
        for enabled in [false, true] {
            let projection = GemmaOptimizationEnvironment.projection(
                for: GemmaOptimizationSettings(weightedR1: enabled)
            )
            #expect(
                projection[GemmaOptimizationEnvironment.weightedUnsortKey]
                    == projection[GemmaOptimizationEnvironment.safeR1Key]
            )
            #expect(Set(projection.keys) == expectedKeys)
        }
    }

    @Test("serving projection preserves the operator trust refinement")
    func servingProjectionPreservesTrust() {
        let projection = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(weightedR1: true),
            getenv: { key in
                key == GemmaOptimizationEnvironment.safeR1Key ? "trust" : nil
            }
        )
        #expect(projection[GemmaOptimizationEnvironment.safeR1Key] == "trust")
        // Only safe R1 is refined; the coupled weighted key stays config-exact.
        #expect(projection[GemmaOptimizationEnvironment.weightedUnsortKey] == "1")
    }

    @Test("trust never overrides a config-OFF route")
    func trustCannotEnableDisabledRoute() {
        let projection = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(weightedR1: false),
            getenv: { _ in "trust" }
        )
        #expect(projection[GemmaOptimizationEnvironment.safeR1Key] == "0")
    }

    @Test("only the exact trust value survives; others collapse to config")
    func nonTrustOperatorValuesCollapse() {
        for shellValue in ["0", "1", "2", "TRUST", "trust ", ""] {
            let projection = GemmaOptimizationEnvironment.projection(
                for: GemmaOptimizationSettings(weightedR1: true),
                getenv: { _ in shellValue }
            )
            #expect(
                projection[GemmaOptimizationEnvironment.safeR1Key] == "1",
                "shell value \(shellValue.debugDescription) must collapse to 1"
            )
        }
    }

    @Test("retained-validation projection never consults the environment")
    func retainedValidationIsHermetic() {
        var consulted = false
        let projection = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(weightedR1: true),
            context: .retainedValidation,
            getenv: { _ in
                consulted = true
                return "trust"
            }
        )
        #expect(projection[GemmaOptimizationEnvironment.safeR1Key] == "1")
        #expect(!consulted, "hermetic context must not read ambient environment")
    }

    @Test("daemon passthrough persists exactly the trust refinement")
    func daemonTrustPassthroughIsExact() {
        let key = GemmaOptimizationEnvironment.safeR1Key
        #expect(
            GemmaOptimizationEnvironment.daemonTrustPassthrough(
                from: [key: "trust", "PATH": "/usr/bin"])
                == [key: "trust"]
        )
        // Config-backed and malformed values never reach the daemon plist.
        for value in ["0", "1", "poison", "TRUST", ""] {
            #expect(
                GemmaOptimizationEnvironment.daemonTrustPassthrough(
                    from: [key: value]).isEmpty
            )
        }
        #expect(GemmaOptimizationEnvironment.daemonTrustPassthrough(from: [:]).isEmpty)
    }

    @Test("apply overwrites every projected value")
    func applyUsesOverwrite() throws {
        var values: [String: String] = [:]
        var overwrites: [String: Int32] = [:]
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: true
        )

        try GemmaOptimizationEnvironment.apply(settings) { name, value, overwrite in
            values[name] = value
            overwrites[name] = overwrite
            return 0
        }

        #expect(values == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "0",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
            "MLX_GATHER_QMM_EXPERT_SLICES": "1",
        ])
        // The application boundary must hand the environment exactly what
        // projection() reports, or the release matrix describes a dispatch
        // that never happened.
        #expect(values == GemmaOptimizationEnvironment.projection(for: settings))
        #expect(Set(overwrites.keys) == expectedKeys)
        #expect(overwrites.values.allSatisfy { $0 == 1 })
    }

    @Test("a rejected key fails the whole application with its errno")
    func applyRejectsPartialLatch() {
        var attempted: [String: String] = [:]
        let settings = GemmaOptimizationSettings()

        do {
            try GemmaOptimizationEnvironment.apply(settings) { name, value, _ in
                attempted[name] = value
                return name == GemmaOptimizationEnvironment.safeR1Key ? ENOMEM : 0
            }
            Issue.record("a rejected key must fail the whole application")
        } catch let error as GemmaOptimizationEnvironment.ApplicationFailure {
            #expect(error == GemmaOptimizationEnvironment.ApplicationFailure(
                keys: [GemmaOptimizationEnvironment.safeR1Key],
                code: ENOMEM
            ))
        } catch {
            Issue.record("expected ApplicationFailure, got \(error)")
        }

        // A rejected key never truncates the attempt, and the values offered
        // stay exactly the projection.
        #expect(attempted == GemmaOptimizationEnvironment.projection(for: settings))
    }

    @Test("every rejected key is reported, ordered, with the first errno")
    func applyReportsAllRejectedKeys() {
        var order: [String] = []

        do {
            try GemmaOptimizationEnvironment.apply(GemmaOptimizationSettings()) {
                name, _, _ in
                order.append(name)
                switch name {
                case GemmaOptimizationEnvironment.safeR1Key: return EINVAL
                case GemmaOptimizationEnvironment.weightedUnsortKey: return EPERM
                default: return 0
                }
            }
            Issue.record("rejected keys must fail the whole application")
        } catch let error as GemmaOptimizationEnvironment.ApplicationFailure {
            #expect(error == GemmaOptimizationEnvironment.ApplicationFailure(
                keys: [
                    GemmaOptimizationEnvironment.safeR1Key,
                    GemmaOptimizationEnvironment.weightedUnsortKey,
                ],
                code: EINVAL
            ))
        } catch {
            Issue.record("expected ApplicationFailure, got \(error)")
        }

        // Sorted application keeps the reported failure identical across runs
        // despite per-process dictionary hash ordering.
        #expect(order == expectedKeys.sorted())
    }

    @Test("failure description names the rejected keys and the errno")
    func failureDescriptionIsPrecise() {
        let failure = GemmaOptimizationEnvironment.ApplicationFailure(
            keys: [
                GemmaOptimizationEnvironment.weightedUnsortKey,
                GemmaOptimizationEnvironment.safeR1Key,
            ],
            code: ENOMEM
        )

        #expect(failure.description.contains(
            GemmaOptimizationEnvironment.weightedUnsortKey))
        #expect(failure.description.contains(
            GemmaOptimizationEnvironment.safeR1Key))
        #expect(failure.description.contains(String(cString: strerror(ENOMEM))))
    }

    @Test("projection excludes dropped packing and prefill controls")
    func droppedControlsAreAbsent() {
        let keys = Set(GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings()
        ).keys)

        #expect(!keys.contains("MLX_GEMMA4_FUSED_EXPERT_GATE_UP"))
        #expect(!keys.contains("MLX_GEMMA4_FUSED_DENSE_GATE_UP"))
        #expect(!keys.contains("DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS"))
        #expect(!keys.contains("DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"))
        #expect(keys == expectedKeys)
    }
}
