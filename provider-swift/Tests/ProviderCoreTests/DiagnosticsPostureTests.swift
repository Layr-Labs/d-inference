import Foundation
import Testing

@testable import ProviderCore


// MARK: - DaemonStateFile

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dstate-\(UUID().uuidString).json")
}

@Test func daemonStateRoundTrips() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let state = DaemonState(
        pid: 4711, version: "0.5.15", writtenAt: 1000, startedAt: 900,
        attestationPublicKey: "active-signer-key",
        trust: .init(trustLevel: "self_signed", status: "online", reason: "awaiting", receivedAt: 950),
        currentModel: "qwen", warmModels: ["qwen"], inferenceActive: true,
        stats: .init(requestsServed: 412, tokensGenerated: 98231, usageGaps: 3))
    DaemonStateFile.write(state, to: url)
    let read = DaemonStateFile.read(from: url)
    #expect(read?.pid == 4711)
    #expect(read?.trust?.reason == "awaiting")
    #expect(read?.stats.usageGaps == 3)
    #expect(read?.currentModel == "qwen")
    #expect(read?.attestationPublicKey == "active-signer-key")
}

@Test("daemon state written before signer identity was added still decodes")
func legacyDaemonStateWithoutAttestationIdentityDecodes() throws {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let legacyJSON = """
        {
          "schema": 1,
          "pid": 4711,
          "version": "0.8.1",
          "written_at": 1000,
          "started_at": 900,
          "warm_models": [],
          "inference_active": false,
          "stats": {
            "requests_served": 0,
            "tokens_generated": 0,
            "usage_gaps": 0
          }
        }
        """
    try Data(legacyJSON.utf8).write(to: url)

    let state = try #require(DaemonStateFile.read(from: url))
    #expect(state.pid == 4711)
    #expect(state.attestationPublicKey == nil)
}

@Test func daemonStateStaleness() {
    let state = DaemonState(pid: 1, version: "x", writtenAt: 1000, startedAt: 1000)
    #expect(state.isStale(now: 1030) == false) // 30s
    #expect(state.isStale(now: 1100) == true)  // 100s > 90s
    #expect(state.uptimeSeconds(now: 1100) == 100)
}

@Test func daemonStateReadHandlesGarbageAndMissing() {
    let missing = tmpStateURL()
    #expect(DaemonStateFile.read(from: missing) == nil)

    let garbage = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: garbage) }
    try? "{not json".data(using: .utf8)!.write(to: garbage)
    #expect(DaemonStateFile.read(from: garbage) == nil)
}

@Test func daemonStateRejectsWrongSchema() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var state = DaemonState(pid: 1, version: "x", writtenAt: 1, startedAt: 1)
    state.schema = 999
    DaemonStateFile.write(state, to: url)
    #expect(DaemonStateFile.read(from: url) == nil, "future schema must be rejected, not mis-decoded")
}

@Test func daemonProcessAliveForSelfAndDeadPid() {
    #expect(daemonProcessAlive(pid: getpid()) == true)
    #expect(daemonProcessAlive(pid: 0) == false)
    #expect(daemonProcessAlive(pid: 999_999) == false) // almost certainly dead
}

private struct EphemeralTestSigner: AttestationSigner {
    let publicKeyBase64: String
    func sign(_ data: Data) throws -> Data { Data() }
}

@Test("daemon state persists the injected ephemeral signer's identity")
func daemonStatePersistsInjectedEphemeralSignerIdentity() async throws {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let signer = EphemeralTestSigner(publicKeyBase64: "ephemeral-active-signer")
    let loop = try ProviderLoop(
        config: ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "test", chipName: "test", chipFamily: .unknown,
                chipTier: .unknown, memoryGb: 32, memoryAvailableGb: 28,
                cpuCores: CpuCores(total: 8, performance: 4, efficiency: 4),
                gpuCores: 10, memoryBandwidthGbs: 100),
            models: [],
            config: ProviderConfig(
                provider: ProviderSettings(name: "daemon-identity-test"),
                backend: BackendSettings(),
                coordinator: CoordinatorSettings())),
        purgeLegacyFiles: false,
        attestationSigner: signer)
    await loop.setDaemonStateFileForTesting(url)
    await loop.writeDaemonState()

    let state = try #require(DaemonStateFile.read(from: url))
    #expect(state.attestationPublicKey == signer.publicKeyBase64)
}

// MARK: - DaemonSlotPostureBuilder (§16.5 per-slot KV/MTP inventory)

@Test("slot posture survives the state file and stays absent for old daemons")
func slotPostureRoundTripsAndIsOptional() {
    let url = tmpStateURL()
    defer { try? FileManager.default.removeItem(at: url) }

    // A daemon that does not report posture must decode, and must decode as
    // NOT REPORTED — never as "this box has no slots".
    DaemonStateFile.write(
        DaemonState(pid: 1, version: "x", writtenAt: 1, startedAt: 1), to: url)
    #expect(DaemonStateFile.read(from: url)?.slots == nil)

    DaemonStateFile.write(
        DaemonState(
            pid: 1, version: "x", writtenAt: 1, startedAt: 1,
            slots: [
                .init(
                    model: "gemma-4-26b", kvBackend: "paged", kvBackendRequested: "paged",
                    mtpEnabled: true, mtpActive: false,
                    mtpInactiveReason: MTPFallbackReason.inertKVUnsupported.rawValue)
            ]),
        to: url)
    let slot = DaemonStateFile.read(from: url)?.slots?.first
    #expect(slot?.kvBackend == "paged")
    #expect(slot?.kvBackendRequested == "paged")
    #expect(slot?.mtpEnabled == true)
    #expect(slot?.mtpActive == false)
    #expect(slot?.mtpInactiveReason == "inert_kv_unsupported")
}

@Test("posture builder pairs each live slot with the selection its config asked for")
func slotPostureBuilderResolvesRequestedSelection() {
    let built = DaemonSlotPostureBuilder.build(
        live: [
            .init(
                model: "gpt-oss-20b", kvBackend: "contiguous", mtpEnabled: false,
                mtpActive: false, mtpInactiveReason: nil),
            .init(
                model: "gemma-4-26b", kvBackend: "paged", mtpEnabled: true, mtpActive: true,
                mtpInactiveReason: nil),
        ],
        requestedGlobal: "auto",
        requestedByModel: ["gemma-4-26b": "paged"],
        lastModelLoadError: nil)

    #expect(built.map(\.model) == ["gemma-4-26b", "gpt-oss-20b"], "sorted for stable output")
    #expect(built[0].kvBackend == "paged")
    #expect(built[0].kvBackendRequested == "paged", "per-model override beats the global")
    #expect(built[1].kvBackendRequested == "auto")
    #expect(built.allSatisfy { $0.loadError == nil })
}

@Test("a refused load becomes a slot entry instead of a hole in the inventory")
func slotPostureBuilderSynthesizesRefusedLoad() {
    // An explicit paged request that cannot be served REFUSES, so no engine
    // and no live slot exists. Absence alone cannot distinguish "paged was
    // refused" from "nobody asked for that model", so the failure gets its
    // own entry with a nil resolved backend.
    let built = DaemonSlotPostureBuilder.build(
        live: [],
        requestedGlobal: "paged",
        requestedByModel: [:],
        lastModelLoadError: .init(
            model: "gemma-4-26b",
            message: "engine_v2: paged KV backend explicitly requested but unavailable — "
                + "kernel preflight failed",
            at: 10),
        now: 20)

    #expect(built.count == 1)
    #expect(built[0].model == "gemma-4-26b")
    #expect(built[0].kvBackend == nil, "no engine was built; a fabricated kind would be a lie")
    #expect(built[0].kvBackendRequested == "paged")
    #expect(built[0].loadError?.contains("explicitly requested but unavailable") == true)
}

@Test("a failure for a model removed from the enabled set is suppressed")
func slotPostureBuilderSuppressesUnconfiguredFailure() {
    let failure = DaemonState.ModelLoadError(model: "gemma-4-26b", message: "refused", at: 10)

    // While the model is still desired, the failed row shows.
    let stillDesired = DaemonSlotPostureBuilder.build(
        live: [], requestedGlobal: "paged", requestedByModel: [:],
        lastModelLoadError: failure,
        desiredModels: ["gemma-4-26b", "gpt-oss-20b"], now: 20)
    #expect(stillDesired.count == 1)
    #expect(stillDesired[0].loadError == "refused")

    // The operator removed the model from `enabled_models`: they resolved
    // the failure the OTHER way, and the row must go with it rather than
    // report NOT SERVING forever for a model nobody wants served.
    let removed = DaemonSlotPostureBuilder.build(
        live: [], requestedGlobal: "paged", requestedByModel: [:],
        lastModelLoadError: failure,
        desiredModels: ["gpt-oss-20b"], now: 20)
    #expect(removed.isEmpty)

    // nil ⇒ unconstrained (`enabled_models` empty serves anything), so
    // membership proves nothing and the row stays.
    let unconstrained = DaemonSlotPostureBuilder.build(
        live: [], requestedGlobal: "paged", requestedByModel: [:],
        lastModelLoadError: failure,
        desiredModels: nil, now: 20)
    #expect(unconstrained.count == 1)
}

@Test("a failure expires after the idle-unload horizon; a fresh one never does")
func slotPostureBuilderExpiresStaleFailure() {
    let trippedAt = 100_000.0
    let failure = DaemonState.ModelLoadError(
        model: "gemma-4-26b", message: "refused", at: trippedAt)
    let build = { (now: Double) in
        DaemonSlotPostureBuilder.build(
            live: [], requestedGlobal: "paged", requestedByModel: [:],
            lastModelLoadError: failure,
            desiredModels: ["gemma-4-26b"], now: now)
    }

    // Fresh — and anywhere inside the horizon — the row shows. The bound is
    // wedge-scale, not stale-scale: a genuinely failed slot must not flap
    // out of `doctor` between two commands of one debugging session.
    #expect(build(trippedAt).count == 1)
    #expect(build(trippedAt + DaemonSlotPostureBuilder.failureMaxAgeSeconds).count == 1)

    // Past the horizon every real slot from the failure's era has been
    // idle-unloaded and rebuilt anyway; the failure is history, not posture.
    #expect(build(trippedAt + DaemonSlotPostureBuilder.failureMaxAgeSeconds + 1).isEmpty)

    // A retry refreshes `at` (recordModelLoadError), so a PERSISTENT failure
    // keeps its row regardless of when the first failure happened.
    let refreshed = DaemonState.ModelLoadError(
        model: "gemma-4-26b", message: "refused again", at: trippedAt + 90_000)
    let rebuilt = DaemonSlotPostureBuilder.build(
        live: [], requestedGlobal: "paged", requestedByModel: [:],
        lastModelLoadError: refreshed,
        desiredModels: ["gemma-4-26b"], now: trippedAt + 90_010)
    #expect(rebuilt.count == 1)
    #expect(rebuilt[0].loadError == "refused again")

    // The horizon IS the idle-unload default — see the constant's rationale.
    #expect(DaemonSlotPostureBuilder.failureMaxAgeSeconds == 3_600)
}

@Test("the expiry horizon follows the CONFIGURED idle timeout, not the fixed default")
func slotPostureBuilderFailureMaxAgeFollowsIdleTimeout() {
    // 0 = idle unload disabled: no era boundary exists, so there is no age
    // past which "every real slot from the failure's era is gone" — the row
    // only clears via a live slot, config removal, or a fresh outcome.
    #expect(DaemonSlotPostureBuilder.failureMaxAge(idleTimeoutMins: 0) == nil)
    // Above the default: a box that keeps slots for 4 h keeps evidence 4 h.
    #expect(DaemonSlotPostureBuilder.failureMaxAge(idleTimeoutMins: 240) == 14_400.0)
    // At/below the default: the wedge-scale floor holds — a 5-minute idle
    // timeout must not flap a genuine failure out of `doctor` mid-session.
    #expect(
        DaemonSlotPostureBuilder.failureMaxAge(idleTimeoutMins: 5)
            == DaemonSlotPostureBuilder.failureMaxAgeSeconds)
    #expect(
        DaemonSlotPostureBuilder.failureMaxAge(idleTimeoutMins: 60)
            == DaemonSlotPostureBuilder.failureMaxAgeSeconds)

    let trippedAt = 100_000.0
    let failure = DaemonState.ModelLoadError(model: "m", message: "refused", at: trippedAt)
    let build = { (maxAge: Double?, now: Double) in
        DaemonSlotPostureBuilder.build(
            live: [], requestedGlobal: "auto", requestedByModel: [:],
            lastModelLoadError: failure, desiredModels: ["m"],
            failureMaxAge: maxAge, now: now)
    }
    // nil horizon: a day-old failure still shows.
    #expect(build(nil, trippedAt + 86_400).count == 1)
    // A 4 h horizon: visible at 4 h, gone past it.
    #expect(build(14_400, trippedAt + 14_400).count == 1)
    #expect(build(14_400, trippedAt + 14_401).isEmpty)
}

@Test("a model that failed once and then loaded reports as serving, not failed")
func slotPostureBuilderDropsSupersededLoadError() {
    let built = DaemonSlotPostureBuilder.build(
        live: [
            .init(
                model: "gemma-4-26b", kvBackend: "paged", mtpEnabled: true, mtpActive: true,
                mtpInactiveReason: nil)
        ],
        requestedGlobal: "paged",
        requestedByModel: [:],
        lastModelLoadError: .init(model: "gemma-4-26b", message: "transient", at: 10),
        now: 20)

    #expect(built.count == 1)
    #expect(built[0].kvBackend == "paged")
    #expect(built[0].loadError == nil)
}

@Test("an unrecognized backend value is recorded as the auto it resolves to")
func slotPostureBuilderNormalizesUnrecognizedSelection() {
    // EngineV2KVBackendPolicy WARNs and falls back to auto. Recording the
    // typo verbatim would make doctor diagnose a mismatch against a
    // selection the engine never attempted.
    let built = DaemonSlotPostureBuilder.build(
        live: [
            .init(
                model: "m", kvBackend: "contiguous", mtpEnabled: false, mtpActive: false,
                mtpInactiveReason: nil)
        ],
        requestedGlobal: "pagd",
        requestedByModel: [:],
        lastModelLoadError: nil)
    #expect(built[0].kvBackendRequested == "auto")
}

// MARK: - Desired set for posture suppression (CLI-selected models)

/// `desiredModelsForPosture` must reflect what the daemon actually SERVES,
/// not just the config file: `--model X` / `--all` select models outside
/// `enabled_models` (the launch path seeds them into `loopConfig.models` →
/// `advertisedModels` while the config object is unchanged), and a failed
/// load of such a model is a refusal the operator asked to see — suppressing
/// its synthetic row as "undesired" lets `doctor` pass misleadingly.
@Suite("Posture desired set (config + CLI selection)")
struct DesiredModelsForPostureTests {

    private func makeLoop(
        advertised: [String],
        enabledModels: [String],
        pinned: String? = nil,
        preload: [String] = []
    ) throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546
            ),
            models: advertised.map {
                ModelInfo(id: $0, modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)
            },
            config: ProviderConfig(
                provider: ProviderSettings(name: "posture-desired-test", memoryReserveGB: 1),
                backend: BackendSettings(
                    model: pinned,
                    enabledModels: enabledModels,
                    idleTimeoutMins: 0,
                    preloadModels: preload
                ),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            )
        )
        return try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
    }

    @Test("a `--model X` selection outside enabled_models stays desired — its failure shows")
    func cliModelOverrideIsDesired() async throws {
        // Launch shape: config allowlists gemma, operator ran `--model org/x`.
        let loop = try makeLoop(
            advertised: ["org/x"], enabledModels: ["gemma-4-26b"])
        let desired = await loop.desiredModelsForPosture()
        #expect(desired?.contains("org/x") == true,
            "the CLI-selected model must never be suppressed as undesired")
        #expect(desired?.contains("gemma-4-26b") == true,
            "the config allowlist still counts — a config-desired failure shows too")

        // And the suppression it feeds agrees: the failed row survives.
        let built = DaemonSlotPostureBuilder.build(
            live: [], requestedGlobal: "auto", requestedByModel: [:],
            lastModelLoadError: .init(model: "org/x", message: "refused", at: 10),
            desiredModels: desired, now: 20)
        #expect(built.count == 1)
        #expect(built[0].loadError == "refused")
    }

    @Test("a `--all` selection makes every advertised model desired")
    func cliAllSelectionIsDesired() async throws {
        // Launch shape: `--all` advertises every scanned model; config
        // allowlist names only one of them.
        let loop = try makeLoop(
            advertised: ["gemma-4-26b", "gpt-oss-20b", "org/other"],
            enabledModels: ["gemma-4-26b"])
        let desired = await loop.desiredModelsForPosture()
        #expect(desired == ["gemma-4-26b", "gpt-oss-20b", "org/other"])
    }

    @Test("the config-only path is unchanged: allowlist ∪ pinned ∪ preload ∪ advertised")
    func configOnlyPathUnchanged() async throws {
        // Config-driven launch: the advertised set IS the config-filtered
        // set, so the union adds nothing new.
        let loop = try makeLoop(
            advertised: ["gemma-4-26b"],
            enabledModels: ["gemma-4-26b"],
            pinned: "org/pinned",
            preload: ["org/preload"])
        let desired = await loop.desiredModelsForPosture()
        #expect(desired == ["gemma-4-26b", "org/pinned", "org/preload"])

        // Empty allowlist still means unconstrained (nil): membership proves
        // nothing when the daemon serves anything pushed to it.
        let unconstrained = try makeLoop(
            advertised: ["org/x"], enabledModels: [])
        #expect(await unconstrained.desiredModelsForPosture() == nil)
    }
}

// MARK: - WarmModelsFormat

@Test func warmModelsLineListsEveryResidentModel() {
    // The whole point of the fix: a box keeps multiple models warm and the CLI
    // must show all of them, not just the LRU slot.
    let line = WarmModelsFormat.warmModelsLine(
        warmModels: ["gemma-4-26b", "gpt-oss-20b"],
        currentModel: "gpt-oss-20b")
    #expect(line == "gemma-4-26b, gpt-oss-20b")
}

@Test func warmModelsLineFallsBackToCurrentWhenWarmSetEmpty() {
    // Back-compat: a daemon predating the warm_models field reports only
    // currentModel; the line must still show that one model, not "none loaded".
    let line = WarmModelsFormat.warmModelsLine(warmModels: [], currentModel: "qwen")
    #expect(line == "qwen")
}

@Test func warmModelsLineEmptyWhenNothingLoaded() {
    #expect(WarmModelsFormat.warmModelsLine(warmModels: [], currentModel: nil) == "none loaded")
    // Custom placeholder is honored.
    #expect(WarmModelsFormat.warmModelsLine(
        warmModels: [], currentModel: nil, emptyPlaceholder: "—") == "—")
}

@Test func warmModelsLineDeduplicatesAndDropsBlanks() {
    let line = WarmModelsFormat.warmModelsLine(
        warmModels: ["a", "", "a", "b"], currentModel: "a")
    #expect(line == "a, b")
}

@Test func mostRecentlyUsedLineReportsLRUSlot() {
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: "gpt-oss-20b") == "gpt-oss-20b")
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: nil) == "none loaded")
    #expect(WarmModelsFormat.mostRecentlyUsedLine(currentModel: "") == "none loaded")
}

@Test func mostRecentlyUsedLabelIsRelabeled() {
    // Regression guard: the single value must not be labeled "Current model",
    // which implied the box served only one model.
    #expect(WarmModelsFormat.mostRecentlyUsedLabel == "Most recently used")
    #expect(WarmModelsFormat.mostRecentlyUsedLabel != "Current model")
}

@Test func modelFitRequiredUsesPerModelActivationFloor() {
    // gpt-oss-20b: padded weights 13.5 + (3.5 GiB measured floor + 1 GiB min
    // serveable KV) = 18.0 — NOT 13.5 + 6.5 = 20.0 sized off gemma-4's B=8
    // peak. The flat floor made every 24 GB catalog-tier box unserveable
    // (#653): usable ≥ 20 GB needs ~22.7 GiB reclaimable out of 24.
    #expect(abs(
        ModelFitDiagnostic.requiredGb(estimatedMemoryGb: 13.5, modelID: "gpt-oss-20b") - 18.0)
        < 0.01)
    // Unmeasured model keeps the flat default: 28 + 6.5 = 34.5.
    #expect(abs(
        ModelFitDiagnostic.requiredGb(estimatedMemoryGb: 28.0, modelID: "gemma-4-26b") - 34.5)
        < 0.01)
    // No id → flat default (regression): 13.5 + 6.5 = 20.0.
    #expect(abs(ModelFitDiagnostic.requiredGb(estimatedMemoryGb: 13.5) - 20.0) < 0.01)
}

@Test func modelFitVerdictReflectsPerModelFloor() {
    // The #653 repro shape: 24 GB box, ~18.5 GB usable headless, gpt-oss-20b
    // padded 13.53. Flat floor demanded 20.0 → permanent fail; the measured
    // floor needs 18.03 → pass.
    let d = ModelFitDiagnostic.diagnose(modelID: "gpt-oss-20b", weightGb: 13.53, usableGb: 18.5)
    #expect(d.level == .pass)
    // An unmeasured model on the same box still fails (25 + 6.5 = 31.5 > 18.5)
    // AND the alternatives suggestion evaluates each candidate with ITS OWN
    // floor — the suggestion models what enabled_models = [candidate] would do.
    let alt = ModelFitDiagnostic.diagnose(
        modelID: "gemma-4-26b", weightGb: 25.0, usableGb: 18.5,
        alternatives: [.init(id: "gpt-oss-20b", weightGb: 13.53)])
    #expect(alt.level == .fail)
    #expect(alt.fix?.contains("gpt-oss-20b") == true)
    #expect(alt.fix?.contains("18.0") == true)
}

@Test func modelFitVerdictTreatsAnEmptyLiveServingSetAsOpenWorld() {
    // A fresh daemon that retired every model advertises [] — authoritative,
    // not "unknown". The target cannot be joining an empty advertised set, so
    // the verdict resolves at the DEFAULT floor (13.53 + 5.5 + 1.0 = 20.03 >
    // 18.5 → FAIL), never the target's solo floor (18.03 → false PASS).
    let empty = ModelFitDiagnostic.diagnose(
        modelID: "gpt-oss-20b", weightGb: 13.53, usableGb: 18.5, servingSetIDs: [])
    #expect(empty.level == .fail)
    // nil (no declared set — offline/single-model box) keeps the solo floor.
    let undeclared = ModelFitDiagnostic.diagnose(
        modelID: "gpt-oss-20b", weightGb: 13.53, usableGb: 18.5, servingSetIDs: nil)
    #expect(undeclared.level == .pass)
}

@Test func modelFitVerdictUsesTheServingSetFloorNotTheTargetsOwn() {
    // A multi-model box: enabled_models = [gpt-oss-20b, gemma-4-26b]. The
    // daemon's load gate carves the max floor over the WHOLE set (6.5 GiB
    // headroom), so gpt-oss needs 13.53 + 6.5 = 20.03 on this box even
    // though its solo requirement is 18.03 — the verdict must say FAIL, not
    // the false PASS a target-only floor would print (the doctor promise:
    // never drift from what the daemon enforces).
    let d = ModelFitDiagnostic.diagnose(
        modelID: "gpt-oss-20b", weightGb: 13.53, usableGb: 18.5,
        servingSetIDs: ["gpt-oss-20b", "gemma-4-26b"])
    #expect(d.level == .fail)
    // Same target, single-model set: back to the solo floor → pass.
    let solo = ModelFitDiagnostic.diagnose(
        modelID: "gpt-oss-20b", weightGb: 13.53, usableGb: 18.5,
        servingSetIDs: ["gpt-oss-20b"])
    #expect(solo.level == .pass)
}

/// The tier arithmetic as the LIVE gate sees it, derived rather than assumed:
/// usable = min(free-plus-inactive, total − MLX used) − max(memory_reserve_gb,
/// total − 0.9·total). With the shipped 4 GiB reserve default, the 24 GB tier
/// needs ~22 GB of free-plus-inactive memory to admit gpt-oss-20b at the 3.5
/// GiB floor — the #653 reporters measured 12.3 and 16.1 GB usable, so the
/// floor alone does not rescue 24 GB; it does turn the 32 GB flap band
/// (15.9 vs 21.6 GB usable in the same minute) into a pass at 21.6.
@Test func modelFitTierArithmeticIsDerivedFromTheLiveGate() {
    let gib = 1024.0 * 1024.0 * 1024.0
    func usable(totalGiB: Double, freePlusInactiveGiB: Double, configReserveGiB: UInt64) -> Double {
        let total = UInt64(totalGiB * gib)
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: total,
            systemAvailableBytes: UInt64(freePlusInactiveGiB * gib),
            gpuActiveBytes: 0,
            gpuCacheBytes: 0,
            reserveBytes: UnifiedMemoryCap.loadReserveBytes(
                physicalBytes: total, configReserveBytes: configReserveGiB * UInt64(gib)))
    }
    let weights = 13.53  // padded gpt-oss-20b catalog estimate
    // 24 GB, default reserve: even the trimmed-headless projection (~18 GB
    // free-plus-inactive after a clean boot) resolves to ~14 usable → fail.
    let headless24 = usable(totalGiB: 24, freePlusInactiveGiB: 18.0, configReserveGiB: 4)
    #expect(headless24 < 18.03)
    #expect(ModelFitDiagnostic.diagnose(modelID: "gpt-oss-20b", weightGb: weights, usableGb: headless24).level != .pass)
    // 24 GB needs ~22 GB free-plus-inactive at the default reserve.
    #expect(usable(totalGiB: 24, freePlusInactiveGiB: 22.1, configReserveGiB: 4) >= 18.03)
    // 32 GB, the #653 flap sample: 21.6 usable passes the 18.03 requirement.
    #expect(ModelFitDiagnostic.diagnose(modelID: "gpt-oss-20b", weightGb: weights, usableGb: 21.6).level == .pass)
    // ...and 15.9 usable still fails, under the new floor as under the old one.
    #expect(ModelFitDiagnostic.diagnose(modelID: "gpt-oss-20b", weightGb: weights, usableGb: 15.9).level != .pass)
}
