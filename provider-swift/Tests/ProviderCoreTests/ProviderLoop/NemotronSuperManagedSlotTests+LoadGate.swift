// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The managed slot's own load gate: pre-accept and eviction compare the room
/// a Super LOAD claim could take in the process ledger with what each
/// configuration requires, as the claim itself decides, on a scripted 128 GiB
/// Mac with one co-resident model.
extension NemotronSuperManagedSlotTests {
    static let coResidentID = "test/co-resident"

    struct CoResidentFixture {
        let loop: ProviderLoop
        let budget: GlobalKVCacheBudget
        /// The co-resident models' engines in `coResidentID(_:)` order; each
        /// shuts down when its model is evicted.
        let engines: [InertStubEngine]
        let directory: URL
        /// The first co-resident model's engine.
        var idle: InertStubEngine { engines[0] }
    }

    /// The id of co-resident model `index`; the first is `coResidentID`.
    static func coResidentID(_ index: Int) -> String { index == 0 ? coResidentID : "\(coResidentID)-\(index)" }

    /// The co-resident model keeps `weightsGiB` of MLX memory resident, and
    /// the OS reports `availableGiB` available, until its engine shuts down;
    /// then the weights are free. It is unmeasured, so the serving set's
    /// activation reserve is the 5.5 GiB default. Super is advertised as the
    /// scanner discovers it; its loader sizes and gates the load as the pinned
    /// checkpoint's on 128 GiB, and a fixture loads.
    static func coResidentFixture(weightsGiB: Double, availableGiB: Double,
                                  configReserveBytes: UInt64 = 0) async throws -> CoResidentFixture {
        try await coResidentFixture(weightsGiB: [weightsGiB], availableGiB: availableGiB,
                                    configReserveBytes: configReserveBytes)
    }

    /// One co-resident model per entry of `weightsGiB`, each as above, the
    /// first least recently used.
    static func coResidentFixture(weightsGiB: [Double], availableGiB: Double,
                                  configReserveBytes: UInt64 = 0) async throws -> CoResidentFixture {
        let stubs = weightsGiB.indices.map { makeInertStubBridge(modelId: coResidentID($0)) }
        let engines = stubs.map(\.engine)
        let weights = weightsGiB.map { UInt64($0 * 1_073_741_824) }, available = UInt64(availableGiB * 1_073_741_824)
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
                                         configReserveBytes: configReserveBytes) {
            let resident = zip(engines, weights).reduce(UInt64(0)) { $0 + ($1.0.shutdownCalls == 0 ? $1.1 : 0) }
            return .init(total: 128 << 30, active: resident, cache: 0,
                         systemAvailable: available + weights.reduce(0, +) - resident)
        }
        let hardware = HardwareInfo(machineModel: "Mac15,14", chipName: "Apple M3 Ultra",
            chipFamily: .m3, chipTier: .ultra, memoryGb: 128, memoryAvailableGb: 128,
            cpuCores: .init(total: 28, performance: 20, efficiency: 8), gpuCores: 60, memoryBandwidthGbs: 819)
        let footprint = NemotronSuperServingPolicy.discoveryFootprint(sizeBytes: 75_010_188_240)
        let superModel = ModelInfo(id: modelID, modelType: "nemotron_h_omni", sizeBytes: 1 << 20,
            estimatedMemoryGb: footprint.estimatedMemoryGb, nativeLoadTransientBytes: footprint.nativeLoadTransientBytes)
        let coResident = weightsGiB.indices.map {
            ModelInfo(id: coResidentID($0), modelType: "gpt_oss", sizeBytes: weights[$0],
                      estimatedMemoryGb: weightsGiB[$0])
        }
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [superModel] + coResident,
            config: .init(provider: .init(name: "super-gate"),
                backend: .init(idleTimeoutMins: 0, maxModelSlots: 3, mtpMode: .auto),
                coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        await loop.setNemotronSuperSlotLoaderForTesting(
            loader(tokenizer: TokenizerHandle(SuperScriptedTokenizer(script: SuperOutputScript())),
                   template: template, physicalBytes: 128 << 30, pinned: true),
            environment: [:])
        for (index, stub) in stubs.enumerated() {
            await loop.modelLoadingInstallSlot(coResidentID(index), bridge: stub.bridge,
                weightsBytes: Int(weights[index]), lastInferenceAt: ContinuousClock.now - .seconds(stubs.count - index))
        }
        await loop.refreshActivationReserve()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("super-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(#"{"model_type":"nemotron_h_omni"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        return CoResidentFixture(loop: loop, budget: budget, engines: engines, directory: directory)
    }

    /// 128 GiB, an idle 30 GiB co-resident model and 92 GiB available: the
    /// claim's room (min(115.2 - 30, 92) less the 5.5 GiB activation reserve,
    /// 79.7 GiB) holds no configuration, so the pinned checkpoint's claim
    /// would be refused, though the ordinary free-memory gate, at the earlier
    /// 69.8 GiB scan-time size, passed this load without evicting. Pre-accept
    /// admits it, eviction removes the idle model, and Super loads: never
    /// accepted, then refused.
    @Test(.timeLimit(.minutes(2)))
    func idleCoResidentModelIsEvictedForTheSuperClaim() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 30, availableGiB: 92)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        // The re-slice, like the ledger, sees the emulated 128 GiB Mac.
        await loop.setEngineV2SlotHooksForTesting(ProviderLoop.EngineV2SlotHooks(
            physicalMemoryBytes: 128 << 30, makeEngine: { _, _ in throw CancellationError() }))
        let room = await loop.nemotronSuperClaimRoomBytes()
        #expect(room == UnifiedMemoryCap.hardCapBytes(physicalBytes: 128 << 30, capFraction: 0.9) - (30 << 30)
            - UnifiedMemoryCap.defaultActivationReserveBytes)
        #expect(!(await Self.claimAdmits(NemotronSuperLoadFit.narrowestRequirementBytes, fixture.budget)))
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID) == false)
        try await loop.ensureModelLoaded(modelId: Self.modelID, revisionDirectory: fixture.directory)
        #expect(fixture.idle.shutdownCalls == 1, "the idle model was evicted")
        #expect(await loop.modelLoadingResidentIDs() == [Self.modelID])
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.fitAttempts.first?.admitted == true)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// The same Mac with the co-resident model serving: nothing can make room,
    /// so pre-accept refuses Super and a load is refused before any claim.
    @Test(.timeLimit(.minutes(1)))
    func busyCoResidentModelRefusesSuperBeforeAccepting() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 30, availableGiB: 92)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        await loop.modelLoadingSetRequest("busy", model: Self.coResidentID)
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let message = "\(try #require(refusal))"
        #expect(message.contains("all loaded models are actively serving"), "\(message)")
        #expect(fixture.idle.shutdownCalls == 0)
        #expect(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID) == nil)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    /// The same Mac with the co-resident model idle, where Super loads by
    /// evicting it, while a wedge's reload cooldown runs or an earlier owner's
    /// native work stays retained: a request is refused before it is accepted,
    /// and a load is refused before anything is evicted for it.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func superSlotStateRefusesBeforeAcceptingOrEvicting(wedged: Bool) async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 30, availableGiB: 92)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        if wedged {
            await loop.setEngineV2LastRecoveryAtForTesting(modelId: Self.modelID, at: .now)
        } else {
            await loop.retainNemotronSuperBytesForTesting(1 << 30)
        }
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        let recorder = Recorder()
        let request = try await Self.send(Self.body(["x"], script: SuperOutputScript()), to: loop,
                                          recorder: recorder, consumer: NodeKeyPair.generate())
        #expect(Self.failure(request.terminal)?.statusCode == 503, "\(request.terminal)")
        #expect(!recorder.snapshot.contains { if case .inferenceAccepted = $0 { true } else { false } })
        var refusal: Error?
        do {
            try await loop.ensureModelLoaded(modelId: Self.modelID, revisionDirectory: fixture.directory)
        } catch { refusal = error }
        let error = try #require(refusal)
        #expect(ProviderLoop.loadErrorStatusCode(for: error) == 503)
        #expect("\(error)".contains(wedged ? "reload refused" : "retained native work"), "\(error)")
        #expect(fixture.idle.shutdownCalls == 0, "nothing is evicted for a refused load")
        #expect(await loop.modelLoadingResidentIDs() == [Self.coResidentID])
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        guard wedged else { return }
        // Once the cooldown has passed, eviction may make room again.
        await loop.setEngineV2LastRecoveryAtForTesting(
            modelId: Self.modelID, at: ContinuousClock.now - ProviderLoop.engineV2RecoveryCooldown)
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID) == false)
    }

    /// The idle model chosen for eviction takes a request while its unload
    /// waits (here behind an MTP upgrade transition) and so declines it: the
    /// eviction plans again from the model still idle instead of refusing
    /// the load. Room 69.7 GiB of 128 GiB beside two idle 20 GiB models: both
    /// evictions reach the planned owner, the one left reaches two requests.
    @Test(.timeLimit(.minutes(1)))
    func evictionPlansAgainWhenItsVictimTakesWork() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: [20, 20], availableGiB: 80)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        let model = try #require(await loop.advertisedModels[Self.modelID])
        let requirements = await loop.nemotronSuperLoadRequirements(model)
        let busy = Self.coResidentID(0)
        await loop.beginMTPUpgradeTransitionForTesting(busy)
        let eviction = Task { try await loop.evictUntilNemotronSuperFits(model, allowEviction: true) }
        #expect(await Self.eventually(within: .seconds(10)) { await loop.mtpUpgradeWaiterCountForTesting(busy) > 0 },
                "the least recently used model's eviction waits behind its transition")
        await loop.modelLoadingSetRequest("busy", model: busy)
        await loop.finishMTPUpgradeTransition(busy)
        try await eviction.value
        #expect(fixture.engines[0].shutdownCalls == 0, "the model that took work stays")
        #expect(fixture.engines[1].shutdownCalls == 1, "the model still idle was evicted instead")
        #expect(await loop.modelLoadingResidentIDs() == [busy])
        // The configuration that eviction reached is admitted.
        let room = await loop.nemotronSuperClaimRoomBytes()
        let reached = try #require(requirements.first { $0 <= room })
        #expect(reached < requirements[0], "evicting one model reaches a fallback, not the planned owner")
        #expect(await Self.claimAdmits(reached, fixture.budget))
    }

    /// A victim that keeps declining (here an autopilot transaction owns
    /// residency) refuses the load after a bounded number of plans instead of
    /// retrying forever; nothing is evicted.
    @Test(.timeLimit(.minutes(1)))
    func evictionGivesUpWhenItsVictimKeepsDeclining() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 30, availableGiB: 92)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        let model = try #require(await loop.advertisedModels[Self.modelID])
        await loop.holdAutopilotResidencyForTesting()
        var refusal: Error?
        do { try await loop.evictUntilNemotronSuperFits(model, allowEviction: true) } catch { refusal = error }
        #expect("\(try #require(refusal))".contains("became unavailable"))
        #expect(fixture.idle.shutdownCalls == 0)
    }

    /// Eviction targets the widest configuration that evicting every idle
    /// model makes room for (102.3, 97.0, 93.3, 88.8, 87.3 and 83.6 GiB on
    /// 128 GiB): an idle model yields to the planned owner, or to a wider
    /// fallback than the room holds now, and stays when evicting it reaches
    /// no wider configuration. When not even the narrowest is reachable,
    /// nothing is evicted.
    @Test(.timeLimit(.minutes(1)), arguments: [
        // Room 89.7 GiB holds two requests; evicting 20 GiB reaches the plan.
        (20, 100, true, true),
        // Room 84.5 GiB holds only 1,024-token chunks; evicting 5 GiB reaches two requests.
        (5, 90, true, true),
        // Evicting 1 GiB reaches no wider configuration than room 83.75 GiB holds.
        (1, 89.25, false, true),
        // Room 78.5 GiB: not even the narrowest is reachable.
        (1, 84, false, false),
    ] as [(Double, Double, Bool, Bool)])
    func evictionMakesRoomForTheWidestReachableConfiguration(weightsGiB: Double, availableGiB: Double,
                                                             evicts: Bool, loads: Bool) async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: weightsGiB, availableGiB: availableGiB)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        let model = try #require(await loop.advertisedModels[Self.modelID])
        let requirements = await loop.nemotronSuperLoadRequirements(model)
        #expect(requirements == [109_816_317_472, 104_179_172_896, 100_152_641_056,
                                 95_387_911_712, 93_777_298_976, 89_750_767_136])
        #expect(requirements.last == NemotronSuperLoadFit.narrowestRequirementBytes)
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID) == !loads)
        // The widest configuration evicting every idle model reaches.
        let reachable = await loop.nemotronSuperClaimRoomBytes() + UInt64(weightsGiB * 1_073_741_824)
        let target = requirements.first { $0 <= reachable }
        var refusal: Error?
        do { try await loop.evictUntilNemotronSuperFits(model, allowEviction: true) } catch { refusal = error }
        #expect(fixture.idle.shutdownCalls == (evicts ? 1 : 0))
        #expect((refusal == nil) == loads, "\(refusal.map { "\($0)" } ?? "")")
        if let target {
            // The real claim of that configuration is admitted.
            #expect(await Self.claimAdmits(target, fixture.budget))
        } else {
            #expect("\(try #require(refusal))".contains("refusing without evicting"))
            #expect(!(await Self.claimAdmits(requirements.last ?? 0, fixture.budget)))
        }
    }

    /// A `memory_reserve_gb` raised to 16 GiB stays free beside Super's claim,
    /// so pre-accept refuses what that claim would: 100 GiB available holds
    /// the narrowest configuration only without the reserve.
    @Test(.timeLimit(.minutes(1)))
    func raisedOperatorReserveRefusesSuperBeforeAccepting() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 1, availableGiB: 100,
                                                       configReserveBytes: 16 << 30)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        let sample = fixture.budget.memoryHeadroomSnapshot()
        #expect(sample.loadClaimRemainingBytes(systemReserveBytes: 0) > NemotronSuperLoadFit.narrowestRequirementBytes)
        #expect(await loop.nemotronSuperClaimRoomBytes() == sample.loadClaimRemainingBytes(systemReserveBytes: 16 << 30))
        #expect(await loop.fastAdmissionReject(modelId: Self.modelID))
        #expect(!(await Self.claimAdmits(NemotronSuperLoadFit.narrowestRequirementBytes, fixture.budget)))
    }

    /// Startup preload (which never evicts) admits Super exactly when its own
    /// gate does, whatever the preloader's free figure says: not beside the
    /// idle 30 GiB model, and, once it is gone, by the claim's room beyond
    /// the narrowest configuration.
    @Test(.timeLimit(.minutes(1)))
    func startupPreloadAdmitsSuperByItsOwnGate() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 30, availableGiB: 92)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        await loop.setStartupPreloadFreeMemoryOverrideForTesting({ 1_000 })
        let short = try #require(await loop.livePreloadRequiredGb(Self.modelID))
        #expect(short > 1_000)
        #expect(await loop.unloadModel(Self.coResidentID))
        let fits = try #require(await loop.livePreloadRequiredGb(Self.modelID))
        let spare = Double(await loop.nemotronSuperClaimRoomBytes())
            - Double(NemotronSuperLoadFit.narrowestRequirementBytes)
        #expect(spare > 0 && abs(fits - (1_000 - spare / 1_073_741_824)) < 1e-9)
    }

    /// The persisted set loads biggest first, Super by its planned
    /// configuration's requirement (102.3 GiB on 128 GiB): before a 90 GiB
    /// model that its scan-time size alone would follow.
    @Test(.timeLimit(.minutes(1)))
    func startupPreloadOrdersSuperByItsPlannedConfiguration() async throws {
        let fixture = try await Self.coResidentFixture(weightsGiB: 90, availableGiB: 20)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop
        let file = fixture.directory.appendingPathComponent("loaded-models.json")
        LoadedModelsStore.write([Self.coResidentID, Self.modelID], to: file)
        await loop.setLoadedModelsFileForTesting(file)
        let scanned = try #require(await loop.advertisedModels[Self.modelID]).estimatedMemoryGb
        #expect(scanned < 90)
        #expect(await loop.startupPreloadPlanForTesting().map(\.modelId) == [Self.modelID, Self.coResidentID])
    }

    /// Whether a Super LOAD claim requiring `bytes` is admitted now (and
    /// released again).
    static func claimAdmits(_ bytes: UInt64, _ budget: GlobalKVCacheBudget) async -> Bool {
        let kvFloor = UInt64(UnifiedMemoryCap.minimumLoadKVBytes)
        guard let lease = await budget.claimPendingLoad(requestID: "super-gate-probe", weightBytes: bytes - kvFloor,
            minimumKVBytes: kvFloor,
            systemReserveBytes: NemotronSuperLoadFit.systemReserveBytes(configReserveBytes: budget.configReserveBytes))
        else { return false }
        return await budget.finishPendingLoad(lease)
    }
}

extension ProviderLoop {
    /// Charges `bytes` as a Super owner whose native work did not retire.
    func retainNemotronSuperBytesForTesting(_ bytes: UInt64) { nemotronSuperRetainedWeightBytes += bytes }

    /// Starts an MTP upgrade transition of `modelID`, which its unload waits behind.
    func beginMTPUpgradeTransitionForTesting(_ modelID: String) { mtpUpgradeTransitions.insert(modelID) }

    func mtpUpgradeWaiterCountForTesting(_ modelID: String) -> Int { mtpUpgradeWaiters[modelID]?.count ?? 0 }

    /// An autopilot transaction owning residency: other callers' evictions decline.
    func holdAutopilotResidencyForTesting() {
        autopilotCommand = .init(commandId: "owns-residency",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000)
    }
}
