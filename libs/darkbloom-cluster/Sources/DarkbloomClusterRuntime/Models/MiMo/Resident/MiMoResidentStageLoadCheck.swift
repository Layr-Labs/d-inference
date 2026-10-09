import Foundation
import MLX
import MLXNN

/// Loads one rank's verified MiMo stage from the registered artifact on this
/// Mac and releases it again, without creating a collective. It qualifies the
/// artifact, the loader and local memory release for that rank. It is not a
/// membership, transport or generation result, and the peer's stage is only
/// inspected.
public enum MiMoResidentStageLoadCheck {
    public struct Receipt: Encodable, Sendable {
        public let schema = "mimo_resident_stage_load_check_v1"
        public let runtimeModelID: String
        public let rank: Int
        public let stageCut: Int
        public let layerCount: Int
        public let sourceLayerStart: Int, sourceLayerEnd: Int
        public let verifiedAggregateSHA256: String
        public let planSHA256: String
        public let stagePlanSHA256: String
        public let storageCommitmentSHA256: String
        public let sourceParameterLayoutSHA256: String
        public let loadedTensorBytes: Int
        public let activeTensorCount: Int
        public let activeBytesBefore: Int
        public let activeBytesLoaded: Int
        public let peakBytesLoaded: Int
        public let activeBytesAfterRelease: Int
        public let cacheBytesAfterRelease: Int
        public let modelReleased: Bool
        /// This Mac's wired memory, from the kernel: before the load, with the
        /// stage loaded (and probed), and after release. Other processes move
        /// it too; a stage held by a standing residency is tens of gigabytes.
        public let systemWiredBytesBefore: Int, systemWiredBytesLoaded: Int, systemWiredBytesAfterRelease: Int
        /// MLX's wired limit for this process before the load and after release.
        public let wiredLimitBytesBefore: Int, wiredLimitBytesAfterRelease: Int
        /// Hashing every manifest file and admitting the metadata.
        public let verifySeconds: Double
        /// Constructing both compact stages and reading this rank's tensors.
        public let loadSeconds: Double
        public let heldSeconds: Double
        public let arithmeticContract: String
        /// Present when the stage was driven alone after its load.
        public let probe: ProbeReceipt?
        public let resourceAdmission: QwenResidentResourceAdmissionReport
        public let collectiveCreated = false
    }

    /// Drives the loaded stage alone, with synthetic input, to time it: one
    /// prompt chunk and then single-token steps. Stage 0 is given pseudo-random
    /// token IDs; stage 1 a pseudo-random residual, so that both route over
    /// many experts as real text does. The output means nothing. It answers
    /// one question early: how long this rank's layers take per token, with and
    /// without the stage's standing residency.
    public struct Probe: Sendable {
        public let prefillTokens: Int
        public let decodeSteps: Int
        public let residency: Bool
        public init(prefillTokens: Int, decodeSteps: Int, residency: Bool) throws {
            guard (1...MiMoRegisteredSpecification.maximumChunkTokens).contains(prefillTokens),
                  (1...512).contains(decodeSteps) else {
                throw ProbeError("A MiMo stage probe takes 1...512 prompt tokens and 1...512 decode steps")
            }
            self.prefillTokens = prefillTokens; self.decodeSteps = decodeSteps; self.residency = residency
        }
    }

    public struct ProbeReceipt: Encodable, Sendable {
        public let input = "synthetic"
        public let residency: Bool
        public let wiredLimitBytes: Int, wiredLimitCeilingBytes: Int
        /// This Mac's wired memory, from the kernel, after the last decode step
        /// and while the residency (if any) was still held.
        public let systemWiredBytesDuringProbe: Int
        public let prefillTokens: Int
        public let prefillSeconds: Double
        public let decodeSteps: Int
        public let decodeSecondsFirst: Double
        public let decodeSecondsMedian: Double, decodeSecondsMinimum: Double, decodeSecondsMaximum: Double
        public let decodeSecondsEach: [Double]
        public let activeBytesAfter: Int, peakBytesAfter: Int
    }

    private static func probe(_ stage: LoadedMiMoLayerStage, _ probe: Probe,
                              check: () throws -> Void) throws -> ProbeReceipt {
        let specification = stage.profile.specification
        let allowance = try MiMoResidentRequestAllowance.derive(specification: specification, plan: stage.plan,
            rank: stage.stageIndex, maximumTokens: probe.prefillTokens + probe.decodeSteps,
            chunkSize: probe.prefillTokens)
        var residency: MiMoStageResidency?
        if probe.residency {
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            residency = try MiMoStageResidency(bytes: stage.receipt.loadedTensorBytes + allowance.reservedBytes)
        }
        defer { try? residency?.end() }
        let caches = stage.model.newCache()
        let last = stage.layerCount - 1, hidden = specification.hidden
        // SplitMix64: the same input on every run and on both Macs.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(stage.stageIndex)
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        func step(_ count: Int) throws -> Double {
            try check()
            let input: MLXArray
            if stage.stageIndex == 0 {
                input = MLXArray((0..<count).map { _ in Int32(next() % UInt64(specification.vocabulary)) })
                    .reshaped([1, count])
            } else {
                input = MLXRandom.normal([1, count, hidden], key: MLXRandom.key(next() & 0xFFFF_FFFF))
                    .asType(stage.activationDType)
            }
            eval(input); Stream.gpu.synchronize()
            let started = DispatchTime.now().uptimeNanoseconds
            let output: MLXArray = try {
                if stage.stageIndex == 0 {
                    let result = try stage.model.forward(inputIDs: input, cache: caches, captureLayers: [last])
                    guard let value = result.layerFeatures[last] else { throw ProbeError("MiMo probe produced no residual") }
                    return value
                }
                return try stage.model.forward(embeddings: input, cache: caches, logitsStart: count - 1)
                    .logits[0..., -1, 0...]
            }()
            eval([output] + caches.flatMap { $0.innerState() })
            Stream.gpu.synchronize()
            try check()
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        }
        // Progress for whoever launched this check (a fault run waits for a decode step).
        log("darkbloom-mimo-stage-probe-v1 rank=\(stage.stageIndex) phase=prefill tokens=\(probe.prefillTokens)"
            + " wired_limit=\(residency?.receipt.appliedBytes ?? 0)")
        let prefill = try autoreleasepool { try step(probe.prefillTokens) }
        var each: [Double] = []
        for index in 0..<probe.decodeSteps {
            if index % 16 == 0 { log("darkbloom-mimo-stage-probe-v1 rank=\(stage.stageIndex) phase=decode step=\(index)") }
            each.append(try autoreleasepool { try step(1) })
        }
        log("darkbloom-mimo-stage-probe-v1 rank=\(stage.stageIndex) phase=done steps=\(probe.decodeSteps)")
        let sorted = each.sorted()
        let after = Memory.snapshot()
        let os = try QwenDenseStageLoadResources.observeOS()
        return ProbeReceipt(residency: probe.residency, wiredLimitBytes: residency?.receipt.appliedBytes ?? 0,
            wiredLimitCeilingBytes: residency?.receipt.ceilingBytes ?? 0,
            systemWiredBytesDuringProbe: os.wiredPages * os.pageSizeBytes,
            prefillTokens: probe.prefillTokens, prefillSeconds: prefill, decodeSteps: probe.decodeSteps,
            decodeSecondsFirst: each[0], decodeSecondsMedian: sorted[sorted.count / 2],
            decodeSecondsMinimum: sorted[0], decodeSecondsMaximum: sorted[sorted.count - 1],
            decodeSecondsEach: each, activeBytesAfter: after.activeMemory, peakBytesAfter: after.peakMemory)
    }

    /// Whether these configuration bytes are a registered MiMo model's.
    public static func handles(configuration: Data) -> Bool {
        (try? MiMoRegisteredSpecification.specification(configuration: configuration)) != nil
    }

    /// Hash and load together; see the specification row for the arithmetic.
    public static let maximumDeadlineSeconds = MiMoRegisteredSpecification.startupSeconds * 3
    public static var supportedCutsDescription: String {
        MiMoRegisteredSpecification.all.map { "\($0.model.rawValue): " + $0.supportedCuts.map(String.init).joined(separator: "|") }
            .joined(separator: "; ")
    }

    public static func run(modelDirectory: URL, rank: Int, stageCut: Int,
                           deadlineUptimeNanoseconds: UInt64, holdSeconds: Int = 0,
                           probe requestedProbe: Probe? = nil) throws -> Receipt {
        guard (0...240).contains(holdSeconds), (0...1).contains(rank), modelDirectory.isFileURL else {
            throw ProbeError("MiMo stage load check takes rank 0|1 and holds for 0...240 seconds")
        }
        let configuration = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                       maximumBytes: 1_048_576)
        let manifest = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                  maximumBytes: 4_194_304)
        let specification = try MiMoRegisteredSpecification.specification(configuration: configuration)
        guard specification.supportedCuts.contains(stageCut), sha256(manifest) == specification.manifestSHA256 else {
            throw ProbeError("MiMo stage load check requires the registered manifest and one of the model's cuts: "
                + specification.supportedCuts.map(String.init).joined(separator: ", "))
        }
        // Before any model construction, as the worker does.
        let arithmetic = try MiMoArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
        let plan = try MiMoLayerStagePlan(configuration: configuration, cut: stageCut)
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stage: LoadedMiMoLayerStage?
        weak var retired: Module?
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            do {
                try settle()
                func systemWired() throws -> Int {
                    let os = try QwenDenseStageLoadResources.observeOS()
                    return os.wiredPages * os.pageSizeBytes
                }
                let before = Memory.snapshot().activeMemory
                let wiredBefore = try systemWired(), limitBefore = MiMoStageResidency.current
                let started = DispatchTime.now().uptimeNanoseconds
                var verified = started
                try autoreleasepool {
                    let source = try prepareMiMoResidentSource(directory: modelDirectory, configuration: configuration,
                        manifest: manifest, specification: specification, plan: plan, check: checked)
                    verified = DispatchTime.now().uptimeNanoseconds
                    stage = try loadMiMoResidentStage(source: source, stageIndex: rank, check: checked,
                                                      constructed: { retired = $0 })
                }
                try settle()
                let finished = DispatchTime.now().uptimeNanoseconds
                let loaded = Memory.snapshot()
                // Plain values only: another reference to the stage would keep the model alive.
                guard let receipt = stage?.receipt, let layers = stage?.layerCount else {
                    throw ProbeError("MiMo stage loader returned no stage")
                }
                let range = plan.stages[rank].sourceRange
                var probed: ProbeReceipt?
                if let requestedProbe, let loadedStage = stage {
                    probed = try Self.probe(loadedStage, requestedProbe, check: checked)
                    try settle()
                }
                let wiredLoaded = try systemWired()
                let holdStarted = DispatchTime.now().uptimeNanoseconds
                let holdUntil = holdStarted + UInt64(holdSeconds) * 1_000_000_000
                while DispatchTime.now().uptimeNanoseconds < holdUntil {
                    try checked()
                    Thread.sleep(forTimeInterval: 0.1)
                }
                let held = Double(DispatchTime.now().uptimeNanoseconds - holdStarted) / 1e9
                // The resident runtime's order: drop the stage, drain both streams, return cached buffers.
                stage = nil
                try settle()
                Memory.clearCache()
                try settle()
                let after = Memory.snapshot()
                return Receipt(runtimeModelID: specification.model.rawValue, rank: rank, stageCut: stageCut,
                    layerCount: layers, sourceLayerStart: range.lowerBound, sourceLayerEnd: range.upperBound,
                    verifiedAggregateSHA256: receipt.verifiedAggregateSHA256, planSHA256: receipt.planSHA256,
                    stagePlanSHA256: receipt.stagePlanSHA256,
                    storageCommitmentSHA256: receipt.storageCommitmentSHA256,
                    sourceParameterLayoutSHA256: receipt.sourceParameterLayoutSHA256,
                    loadedTensorBytes: receipt.loadedTensorBytes, activeTensorCount: receipt.activeTensors.count,
                    activeBytesBefore: before, activeBytesLoaded: loaded.activeMemory,
                    peakBytesLoaded: loaded.peakMemory,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelReleased: retired == nil,
                    systemWiredBytesBefore: wiredBefore, systemWiredBytesLoaded: wiredLoaded,
                    systemWiredBytesAfterRelease: try systemWired(),
                    wiredLimitBytesBefore: limitBefore, wiredLimitBytesAfterRelease: MiMoStageResidency.current,
                    verifySeconds: Double(verified - started) / 1e9, loadSeconds: Double(finished - verified) / 1e9,
                    heldSeconds: holdSeconds == 0 ? 0 : held, arithmeticContract: arithmetic.contract,
                    probe: probed, resourceAdmission: .current)
            } catch {
                var primary: Error = error
                stage = nil
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                // Prefer a recorded native fault over a secondary Swift error.
                do { try nativeError.check() } catch { primary = error }
                let after = Memory.snapshot()
                throw QwenResidentReleasedFailure(failure: String(describing: primary),
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelsReleased: [retired == nil], resourceAdmission: .current)
            }
        }
    }
}
