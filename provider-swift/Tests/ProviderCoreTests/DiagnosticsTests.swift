import Foundation
import Testing
@testable import ProviderCore

// MARK: - TrustReasonCatalog

@Test func trustReasonCatalogMapsKnownReasons() {
    // Every reason string the coordinator emits must produce a non-empty,
    // operator-actionable message (and a fix for the actionable ones).
    let reasons = [
        "SE attestation verified, awaiting MDM verification",
        "SE attestation verified, awaiting MDM/ACME upgrade", // pre-removal coordinator
        "MDM verification passed",
        "recovered after transient deroute",
        "timeout", "no response", "nonce mismatch", "public key mismatch",
        "empty signature", "SIP status not reported", "SIP disabled",
        "Secure Boot disabled", "RDMA status not reported — provider must update to v0.2.0+",
        "binary hash mismatch", "binary hash changed from registration attestation",
        "attested binary hash missing", "binary hash missing",
        "valid attestation required for binary hash policy",
        "active model weight hash mismatch",
    ]
    for r in reasons {
        let advice = TrustReasonCatalog.advice(level: "self_signed", status: "untrusted", reason: r)
        #expect(!advice.message.isEmpty, "empty message for reason \(r)")
    }
}

@Test func trustReasonCatalogPrefixMatchesSignatureFailures() {
    let a = TrustReasonCatalog.advice(level: "hardware", status: "untrusted",
                                      reason: "signature verification failed: bad point")
    #expect(a.message.lowercased().contains("signature"))
    #expect(a.fix != nil)

    let b = TrustReasonCatalog.advice(level: "hardware", status: "untrusted",
                                      reason: "status signature verification failed: canonical mismatch")
    #expect(b.fix != nil)
}

@Test func trustReasonCatalogEchoesUnknownReasonVerbatim() {
    let novel = "some-brand-new-coordinator-reason-v9"
    let advice = TrustReasonCatalog.advice(level: "self_signed", status: "online", reason: novel)
    #expect(advice.message.contains(novel), "unknown reason must be surfaced verbatim, not hidden")
}

@Test func trustReasonCatalogLevels() {
    #expect(TrustReasonCatalog.level(trustLevel: "hardware", status: "online") == .pass)
    #expect(TrustReasonCatalog.level(trustLevel: "self_signed", status: "online") == .warn)
    #expect(TrustReasonCatalog.level(trustLevel: "hardware", status: "untrusted") == .fail)
}

// MARK: - OSStatusCatalog

@Test func osStatusCatalogMapsLockedKey() {
    let a = OSStatusCatalog.advice(osStatus: -25308)
    #expect(a.message.contains("-25308"))
    #expect(a.fix?.contains("console") == true)
}

@Test func osStatusCatalogMapsMissingEntitlement() {
    let a = OSStatusCatalog.advice(osStatus: -34018)
    #expect(a.message.lowercased().contains("entitlement"))
}

@Test func osStatusCatalogUnknownEchoesCode() {
    let a = OSStatusCatalog.advice(osStatus: -99999)
    #expect(a.message.contains("-99999"))
}

// MARK: - ModelFitDiagnostic

@Test func modelFitFailsWhenTooLarge() {
    // Cap-aware gate: required = weights + loadHeadroom (activation reserve
    // 5.5 GB + min serveable KV 1 GB = 6.5 GB). 25 GB weights needs 31.5 GB
    // > 21 usable → fail.
    let d = ModelFitDiagnostic.diagnose(modelID: "big", weightGb: 25.0, usableGb: 21.0)
    #expect(d.level == .fail)
    #expect(d.message.contains("31.5"))
}

@Test func modelFitPassesWhenItFits() {
    // 5 GB weights needs 5 + 6.5 = 11.5 GB ≤ 21 usable → pass.
    let d = ModelFitDiagnostic.diagnose(modelID: "small", weightGb: 5.0, usableGb: 21.0)
    #expect(d.level == .pass)
}

@Test func usableInferenceGbMatchesProviderAccounting() {
    // Delegates to ModelLoadAdmission.freeForLoadGb. Must match
    // ProviderLoop.availableMemoryGb(): real free minus reserve, NO 0.7 discount.
    // 32 GB box, 4 GB reserve, idle, OS-available unknown: 32 − 4 = 28.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4) - 28.0) < 0.01)
    // With 5 GB GPU active: 32 − 5 − 4 = 23.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, gpuActiveGb: 5) - 23.0) < 0.01)
    // Clamped to live OS-available memory when that is the tighter bound:
    // 32 GB box but OS reports only 10 GB available → 10 − 4 = 6.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 10) - 6.0) < 0.01)
    // Never negative.
    #expect(ModelFitDiagnostic.usableInferenceGb(totalGb: 8, reserveGb: 16) == 0)
}

@Test func usableInferenceGbHonorsThe90PercentCapOnBigBoxes() {
    // On a big box the 90% unified cap holds back MORE than the 4 GB config
    // reserve, and the doctor verdict must reflect that (matching the runtime
    // gate's loadReserveBytes). 128 GB box: cap = 115.2 GB → reserve = 12.8 GB,
    // so usable = 128 − 12.8 = 115.2, NOT 128 − 4 = 124.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 128, reserveGb: 4) - 115.2) < 0.05)
    // 64 GB box: cap 57.6 → usable 57.6, not 60.
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 64, reserveGb: 4) - 57.6) < 0.05)
    // Small/mid box where config reserve already exceeds the cap's 10%: config
    // wins, behavior unchanged (32 − 4 = 28, since cap-implied 3.2 < 4).
    #expect(abs(ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4) - 28.0) < 0.01)
}

@Test func modelFitMatchesRuntimeGateNotRawAvailable() {
    // Parity with the runtime gate, cap-aware: gpt-oss (~13.5 GB weights)
    // needs 13.5 + 6.5 (activation 5.5 + min-KV 1) = 20 GB. On a 32 GB box
    // with the OS reporting ~30 GB free it FITS — usable 30 − 4 = 26 ≥ 20 —
    // matching ProviderLoop, which would load it with serveable KV headroom.
    // (A 24 GB box no longer clears this bar at all under the v0.8.0
    // reserve: 22 − 4 = 18 < 20. That refusal is the point of the raise —
    // the daemon was spending the memory at B=8 whether or not the ledger
    // admitted it.)
    let usable = ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 30)
    let ok = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: usable)
    #expect(ok.level == .pass, "doctor must agree with the runtime gate that gpt-oss fits with serveable KV")
    // But a tighter box (OS only 22 GB free → usable 18) must FAIL: 18 < 20.
    // Pre-cap-aware this wrongly "passed", then the runtime KV gate would
    // have rejected every request — the bug this stricter headroom fixes.
    let tight = ModelFitDiagnostic.usableInferenceGb(totalGb: 32, reserveGb: 4, systemAvailableGb: 22)
    let bad = ModelFitDiagnostic.diagnose(modelID: "gpt-oss", weightGb: 13.5, usableGb: tight)
    #expect(bad.level == .fail)
}

@Test func modelFitSuggestsFittingAlternatives() {
    let alts = [
        ModelFitDiagnostic.ModelOption(id: "small", weightGb: 5.0),
        ModelFitDiagnostic.ModelOption(id: "huge", weightGb: 40.0),
    ]
    // huge needs 46.5 > 21 → fail; small needs 11.5 ≤ 21 → suggested.
    let d = ModelFitDiagnostic.diagnose(modelID: "huge", weightGb: 40.0, usableGb: 21.0, alternatives: alts)
    #expect(d.level == .fail)
    #expect(d.fix?.contains("small") == true)
    #expect(d.fix?.contains("huge") != true) // huge doesn't fit, must not be suggested
}

// MARK: - VersionDiagnostic

@Test func versionParseAndCompare() {
    #expect(VersionDiagnostic.parse("v1.2.3") == [1, 2, 3])
    #expect(VersionDiagnostic.parse("0.5.15-beta") == [0, 5, 15])
    #expect(VersionDiagnostic.parse("garbage") == nil)
    #expect(VersionDiagnostic.compare("0.5.15", "0.6.0") == -1)
    #expect(VersionDiagnostic.compare("1.0.0", "1.0.0") == 0)
    #expect(VersionDiagnostic.compare("2.0.0", "1.9.9") == 1)
}

@Test func versionDiagnoseBelowMinimumFails() {
    let d = VersionDiagnostic.diagnose(current: "0.5.15", minimum: "0.6.0", latest: "0.7.0")
    #expect(d.level == .fail)
}

@Test func versionDiagnoseBehindLatestWarns() {
    let d = VersionDiagnostic.diagnose(current: "0.6.0", minimum: "0.5.0", latest: "0.7.0")
    #expect(d.level == .warn)
}

@Test func versionDiagnoseCurrentPasses() {
    let d = VersionDiagnostic.diagnose(current: "0.7.0", minimum: "0.5.0", latest: "0.7.0")
    #expect(d.level == .pass)
}

// MARK: - DaemonSlotPostureBuilder (§16.5 per-slot KV/MTP inventory)
//
// DaemonState/DaemonStateFile themselves moved to ProviderCoreFoundation (the
// app links the schema without MLX); their round-trip tests moved to
// DaemonStateFileTests there. The JOIN below stays because it consults
// EngineV2KVBackendPolicy (inference runtime).

private func tmpStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dstate-\(UUID().uuidString).json")
}

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
