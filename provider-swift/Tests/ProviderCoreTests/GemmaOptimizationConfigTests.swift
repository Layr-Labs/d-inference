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
        "MLX_QWEN_DIRECT_EXPERT_REDUCTION",
    ]

    @Test("projection emits the selected controls")
    func exactProjection() {
        let enabled = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(),
            getenv: { _ in nil }
        )
        #expect(enabled == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "18",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
            "MLX_GATHER_QMM_EXPERT_SLICES": "trust",
            "MLX_QWEN_DIRECT_EXPERT_REDUCTION": "1",
        ])

        let disabled = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(
                prefillLayer18: false,
                weightedR1: false
            ),
            getenv: { _ in nil }
        )
        #expect(disabled == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "0",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "0",
            "MLX_GATHER_QMM_EXPERT_SLICES": "0",
            "MLX_QWEN_DIRECT_EXPERT_REDUCTION": "1",
        ])
    }

    @Test("Qwen direct reduction defaults on and honors serving rollback")
    func qwenDirectReductionDefaultAndRollback() {
        let enabled = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(), getenv: { _ in nil })
        #expect(enabled[GemmaOptimizationEnvironment.qwenDirectExpertReductionKey] == "1")

        let rolledBack = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(),
            getenv: { key in
                key == GemmaOptimizationEnvironment.qwenDirectExpertReductionKey ? "0" : nil
            })
        #expect(rolledBack[GemmaOptimizationEnvironment.qwenDirectExpertReductionKey] == "0")

        let validation = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(), context: .retainedValidation,
            getenv: { _ in "0" })
        #expect(validation[GemmaOptimizationEnvironment.qwenDirectExpertReductionKey] == "1")
    }

    @Test("weighted unsort and safe R1 stay coupled on or off")
    func weightedR1IsAtomic() {
        for enabled in [false, true] {
            let projection = GemmaOptimizationEnvironment.projection(
                for: GemmaOptimizationSettings(weightedR1: enabled),
                getenv: { _ in nil }
            )
            let unsort = projection[GemmaOptimizationEnvironment.weightedUnsortKey]
            let slices = projection[GemmaOptimizationEnvironment.safeR1Key]
            if enabled {
                #expect(unsort == "1")
                #expect(slices == GemmaOptimizationEnvironment.trustedSafeR1Value)
            } else {
                #expect(unsort == "0")
                #expect(slices == "0")
            }
            #expect(Set(projection.keys) == expectedKeys)
        }
    }

    @Test("serving default is trust when the route is on")
    func servingDefaultsToTrust() {
        let projection = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(weightedR1: true),
            getenv: { _ in nil }
        )
        #expect(
            projection[GemmaOptimizationEnvironment.safeR1Key]
                == GemmaOptimizationEnvironment.trustedSafeR1Value
        )
        #expect(projection[GemmaOptimizationEnvironment.weightedUnsortKey] == "1")
    }

    @Test("exact drain export restores the descriptor-retract readback")
    func servingProjectionHonorsDrain() {
        let projection = GemmaOptimizationEnvironment.projection(
            for: GemmaOptimizationSettings(weightedR1: true),
            getenv: { key in
                key == GemmaOptimizationEnvironment.safeR1Key
                    ? GemmaOptimizationEnvironment.drainedSafeR1Value : nil
            }
        )
        #expect(
            projection[GemmaOptimizationEnvironment.safeR1Key]
                == GemmaOptimizationEnvironment.drainedSafeR1Value
        )
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

    @Test("only the exact drain value survives; others become serving trust")
    func onlyExactDrainSurvives() {
        for shellValue in ["0", "2", "TRUST", "trust ", "trust", ""] {
            let projection = GemmaOptimizationEnvironment.projection(
                for: GemmaOptimizationSettings(weightedR1: true),
                getenv: { _ in shellValue }
            )
            #expect(
                projection[GemmaOptimizationEnvironment.safeR1Key]
                    == GemmaOptimizationEnvironment.trustedSafeR1Value,
                "shell value \(shellValue.debugDescription) must become trust"
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

    @Test("daemon passthrough persists exactly the drain refinement")
    func daemonDrainPassthroughIsExact() {
        let key = GemmaOptimizationEnvironment.safeR1Key
        #expect(
            GemmaOptimizationEnvironment.daemonDrainPassthrough(
                from: [key: "1", "PATH": "/usr/bin"])
                == [key: "1"]
        )
        // Serving-default and malformed values never reach the daemon plist.
        for value in ["0", "trust", "poison", "TRUST", ""] {
            #expect(
                GemmaOptimizationEnvironment.daemonDrainPassthrough(
                    from: [key: value]).isEmpty
            )
        }
        #expect(GemmaOptimizationEnvironment.daemonDrainPassthrough(from: [:]).isEmpty)
    }

    @Test("apply overwrites every projected value")
    func applyUsesOverwrite() throws {
        var values: [String: String] = [:]
        var overwrites: [String: Int32] = [:]
        let settings = GemmaOptimizationSettings(
            prefillLayer18: false,
            weightedR1: true
        )
        let getenv: (String) -> String? = { _ in nil }

        try GemmaOptimizationEnvironment.apply(
            settings, getenv: getenv
        ) { name, value, overwrite in
            values[name] = value
            overwrites[name] = overwrite
            return 0
        }

        #expect(values == [
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "0",
            "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
            "MLX_GATHER_QMM_EXPERT_SLICES": "trust",
            "MLX_QWEN_DIRECT_EXPERT_REDUCTION": "1",
        ])
        // The application boundary must hand the environment exactly what
        // projection() reports, or the release matrix describes a dispatch
        // that never happened.
        #expect(values == GemmaOptimizationEnvironment.projection(
            for: settings, getenv: getenv))
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
