// Profiler wire objects (slice 2 contract): the per-attempt `profile` object
// carried on `inference_complete` / `inference_error`, and the heartbeat
// `telemetry` sub-objects on `BackendSlotCapacity` / `BackendCapacity`.
//
// CLOSED BY CONSTRUCTION. Every field is a number, a bool, a closed enum, or
// a nested object of the same. There is deliberately no `String` stored
// property anywhere in this file: nothing derived from a request, an error,
// a URL, a path, or a template can ride these objects. Every field is
// optional and encoded with `encodeIfPresent` (synthesized Codable on
// optionals) — absent == "did not happen" / unknown, which is the mixed-fleet
// sentinel the coordinator relies on (an old provider omits the whole
// object; a new provider always sends it, possibly sparse).
//
// Mirrored in coordinator/protocol/profile.go (`InferenceProfile`,
// `EngineProfile`, `SlotTelemetry`, `CapacityTelemetry`) — keep the key sets
// in sync (the shared fixture test asserts them).

import Foundation

// MARK: - Closed enums

/// Tolerant string-backed enum: an unknown wire value decodes to `.other`
/// instead of failing the whole message (the coordinator folds the same way
/// and flags `enum_folded`). Encoding always writes the exact raw value.
public protocol ProfilerFoldingEnum: RawRepresentable, Codable, Sendable, Equatable,
    CaseIterable where RawValue == String
{
    static var other: Self { get }
}

extension ProfilerFoldingEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How the engine admitted the request against its first-content deadline.
public enum DeadlineMode: String, ProfilerFoldingEnum {
    /// No deadline was attached to the request.
    case none
    /// Atomic projected admission (`engine.submit(_, firstTokenDeadline:)`).
    case projected
    /// A deadline was present but the request went through ordinary submit
    /// (projection off / unmeasured / multimodal); only absolute expiry applies.
    case legacy
    case other
}

/// `ProcessInfo.thermalState` at finish. Distinct from the heartbeat's
/// `ThermalState` (Enums.swift), which has no `other` fold case.
public enum ProfileThermalState: String, ProfilerFoldingEnum {
    case nominal
    case fair
    case serious
    case critical
    case other

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .other
        }
    }
}

/// Where in the request lifecycle a coordinator `cancel` landed, derived
/// from the stamps present at cancel receipt.
public enum CancelStage: String, ProfilerFoldingEnum {
    case none
    case preAccept = "pre_accept"
    case preEngine = "pre_engine"
    case prefill
    case decode
    case postTerminal = "post_terminal"
    case other
}

/// Engine finish reason (slice 3 producer; decodable now).
public enum EngineFinishReason: String, ProfilerFoldingEnum {
    case stop
    case length
    case stopSequence = "stop_sequence"
    case cancelled
    case error
    case other
}

/// Last kernel memory-pressure level observed by `MemoryPressureMonitor`.
public enum MemoryPressureLevelWire: String, ProfilerFoldingEnum {
    case normal
    case warning
    case critical
    case other
}

// MARK: - Engine sub-object (slice 3 fills it)

/// Nanosecond offsets from engine enqueue (`DispatchTime` domain) plus
/// per-request engine counters. Slice 2 never populates it (the whole
/// `engine` key is omitted); the shape exists so both sides decode it.
public struct EngineProfile: Codable, Sendable, Equatable {
    public var admittedNs: Int64?
    public var kvAllocatedNs: Int64?
    public var prefillFirstLaunchNs: Int64?
    public var promptComputedNs: Int64?
    public var firstTokenNs: Int64?
    public var finishedNs: Int64?
    public var readmissions: Int64?
    public var preemptions: Int64?
    public var capacityRequeues: Int64?
    public var prefillChunks: Int64?
    public var packedPrefillChunks: Int64?
    public var visionChunks: Int64?
    public var soloStripeChunks: Int64?
    public var prefillChunkTokensMax: Int64?
    public var decodeSteps: Int64?
    public var chainedDecodeSteps: Int64?
    public var batchRowsSum: Int64?
    public var batchRowsMin: Int64?
    public var batchRowsMax: Int64?
    public var stepLatencyNsSum: Int64?
    public var stepLatencyNsMax: Int64?
    public var mtpRounds: Int64?
    public var mtpProposed: Int64?
    public var mtpAccepted: Int64?
    public var pausedNs: Int64?
    public var pauseCount: Int64?
    public var detokDelayFirstNs: Int64?
    public var prefixLookupNs: Int64?
    public var prefixAdoptionNs: Int64?
    public var finishReason: EngineFinishReason?

    enum CodingKeys: String, CodingKey {
        case admittedNs = "admitted_ns"
        case kvAllocatedNs = "kv_allocated_ns"
        case prefillFirstLaunchNs = "prefill_first_launch_ns"
        case promptComputedNs = "prompt_computed_ns"
        case firstTokenNs = "first_token_ns"
        case finishedNs = "finished_ns"
        case readmissions
        case preemptions
        case capacityRequeues = "capacity_requeues"
        case prefillChunks = "prefill_chunks"
        case packedPrefillChunks = "packed_prefill_chunks"
        case visionChunks = "vision_chunks"
        case soloStripeChunks = "solo_stripe_chunks"
        case prefillChunkTokensMax = "prefill_chunk_tokens_max"
        case decodeSteps = "decode_steps"
        case chainedDecodeSteps = "chained_decode_steps"
        case batchRowsSum = "batch_rows_sum"
        case batchRowsMin = "batch_rows_min"
        case batchRowsMax = "batch_rows_max"
        case stepLatencyNsSum = "step_latency_ns_sum"
        case stepLatencyNsMax = "step_latency_ns_max"
        case mtpRounds = "mtp_rounds"
        case mtpProposed = "mtp_proposed"
        case mtpAccepted = "mtp_accepted"
        case pausedNs = "paused_ns"
        case pauseCount = "pause_count"
        case detokDelayFirstNs = "detok_delay_first_ns"
        case prefixLookupNs = "prefix_lookup_ns"
        case prefixAdoptionNs = "prefix_adoption_ns"
        case finishReason = "finish_reason"
    }

    public init() {}
}

// MARK: - Per-attempt profile

/// The `profile` object. Offsets are microseconds from `t0p` = WebSocket
/// frame receipt on the provider's `SuspendingClock` (mach_absolute_time —
/// the same domain as the engine's `DispatchTime`); durations are
/// microseconds; `wall_ms` is the single untrusted wall anchor.
public struct InferenceProfile: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int?
    public var wallMs: Int64?

    // Offsets (µs from t0p)
    public var dequeuedUs: Int64?
    public var decryptedUs: Int64?
    public var parsedUs: Int64?
    public var admissionUs: Int64?
    public var acceptedSentUs: Int64?
    public var loadWaitStartUs: Int64?
    public var loadWaitEndUs: Int64?
    public var taskSpawnedUs: Int64?
    public var promptPrepStartUs: Int64?
    public var promptPrepEndUs: Int64?
    public var engineSubmitUs: Int64?
    public var engineAdmittedUs: Int64?
    public var firstDeltaUs: Int64?
    public var firstFrameUs: Int64?
    public var lastDeltaUs: Int64?
    public var terminalBuiltUs: Int64?
    public var terminalSentUs: Int64?
    public var cancelReceivedUs: Int64?
    public var cancelAbortedUs: Int64?
    public var totalUs: Int64?

    // Durations (µs)
    public var toolConstraintUs: Int64?
    public var visionPrepUs: Int64?
    public var ssdStageUs: Int64?
    public var kvReserveUs: Int64?
    public var flushUs: Int64?
    public var seSignUs: Int64?
    public var sleptUs: Int64?

    // Counts / bytes / booleans
    public var promptTokens: Int64?
    public var framesEmitted: Int64?
    public var bytesEmitted: Int64?
    public var usageRecovered: Bool?
    public var loadCold: Bool?
    public var loadParked: Bool?
    public var runningAtAdmit: Int64?
    public var waitingAtAdmit: Int64?
    public var queuedPrefillTokensAtAdmit: Int64?
    public var kvBytesInUseAtAdmit: Int64?
    public var kvBytesCapacity: Int64?
    public var stepsAtSubmit: Int64?
    public var stepsAtFinish: Int64?
    public var projectedPrefillTokens: Int64?
    public var projectedDecodeTokens: Int64?
    public var projectedServiceUs: Int64?
    /// Remaining first-content budget at the ENGINE'S VERDICT instant —
    /// present on admits AND on `deadline_unreachable` refusals (T2-02
    /// stamps the refusal's projection too). Its presence does not mean
    /// the engine admitted the request: admission is signalled by
    /// `engine_admitted_us` alone. Mirrored in coordinator/protocol/profile.go.
    public var budgetRemainingAtAdmitUs: Int64?
    public var mtpActive: Bool?
    public var partialPrefillCap: Int64?
    public var mlxActiveBytesAtFinish: Int64?
    public var mlxPeakBytes: Int64?
    public var lowPowerMode: Bool?
    public var tokensAfterCancel: Int64?

    // Closed enums
    public var deadlineMode: DeadlineMode?
    public var thermalState: ProfileThermalState?
    public var cancelStage: CancelStage?

    // Engine sub-object (slice 3)
    public var engine: EngineProfile?

    enum CodingKeys: String, CodingKey {
        case schema
        case wallMs = "wall_ms"
        case dequeuedUs = "dequeued_us"
        case decryptedUs = "decrypted_us"
        case parsedUs = "parsed_us"
        case admissionUs = "admission_us"
        case acceptedSentUs = "accepted_sent_us"
        case loadWaitStartUs = "load_wait_start_us"
        case loadWaitEndUs = "load_wait_end_us"
        case taskSpawnedUs = "task_spawned_us"
        case promptPrepStartUs = "prompt_prep_start_us"
        case promptPrepEndUs = "prompt_prep_end_us"
        case engineSubmitUs = "engine_submit_us"
        case engineAdmittedUs = "engine_admitted_us"
        case firstDeltaUs = "first_delta_us"
        case firstFrameUs = "first_frame_us"
        case lastDeltaUs = "last_delta_us"
        case terminalBuiltUs = "terminal_built_us"
        case terminalSentUs = "terminal_sent_us"
        case cancelReceivedUs = "cancel_received_us"
        case cancelAbortedUs = "cancel_aborted_us"
        case totalUs = "total_us"
        case toolConstraintUs = "tool_constraint_us"
        case visionPrepUs = "vision_prep_us"
        case ssdStageUs = "ssd_stage_us"
        case kvReserveUs = "kv_reserve_us"
        case flushUs = "flush_us"
        case seSignUs = "se_sign_us"
        case sleptUs = "slept_us"
        case promptTokens = "prompt_tokens"
        case framesEmitted = "frames_emitted"
        case bytesEmitted = "bytes_emitted"
        case usageRecovered = "usage_recovered"
        case loadCold = "load_cold"
        case loadParked = "load_parked"
        case runningAtAdmit = "running_at_admit"
        case waitingAtAdmit = "waiting_at_admit"
        case queuedPrefillTokensAtAdmit = "queued_prefill_tokens_at_admit"
        case kvBytesInUseAtAdmit = "kv_bytes_in_use_at_admit"
        case kvBytesCapacity = "kv_bytes_capacity"
        case stepsAtSubmit = "steps_at_submit"
        case stepsAtFinish = "steps_at_finish"
        case projectedPrefillTokens = "projected_prefill_tokens"
        case projectedDecodeTokens = "projected_decode_tokens"
        case projectedServiceUs = "projected_service_us"
        case budgetRemainingAtAdmitUs = "budget_remaining_at_admit_us"
        case mtpActive = "mtp_active"
        case partialPrefillCap = "partial_prefill_cap"
        case mlxActiveBytesAtFinish = "mlx_active_bytes_at_finish"
        case mlxPeakBytes = "mlx_peak_bytes"
        case lowPowerMode = "low_power_mode"
        case tokensAfterCancel = "tokens_after_cancel"
        case deadlineMode = "deadline_mode"
        case thermalState = "thermal_state"
        case cancelStage = "cancel_stage"
        case engine
    }

    public init(schema: Int? = InferenceProfile.currentSchema, wallMs: Int64? = nil) {
        self.schema = schema
        self.wallMs = wallMs
    }

    // MARK: - Wire ranges (coordinator `api/profiler_provider.go` validator)

    /// `_us` fields: [0, 3.6e9] (one hour).
    public static let maxWireMicros: Int64 = 3_600_000_000
    /// `_ns` fields: [0, 3.6e12].
    public static let maxWireNanos: Int64 = 3_600_000_000_000
    /// Counts: [0, 1e9].
    public static let maxWireCount: Int64 = 1_000_000_000
    /// Bytes: [0, 2^48].
    public static let maxWireBytes: Int64 = 1 << 48

    /// Every numeric pinned into the validator's accepted range (negatives to
    /// 0, overflows to the ceiling). Producers call this at the wire boundary
    /// so a lifetime counter (engine `steps_executed`) or an absurd duration
    /// degrades one field instead of invalidating the whole record.
    public func saturatedToWireRanges() -> InferenceProfile {
        @inline(__always) func us(_ v: Int64?) -> Int64? { v.map { min(max(0, $0), Self.maxWireMicros) } }
        @inline(__always) func n(_ v: Int64?) -> Int64? { v.map { min(max(0, $0), Self.maxWireCount) } }
        @inline(__always) func b(_ v: Int64?) -> Int64? { v.map { min(max(0, $0), Self.maxWireBytes) } }
        var p = self
        p.dequeuedUs = us(p.dequeuedUs)
        p.decryptedUs = us(p.decryptedUs)
        p.parsedUs = us(p.parsedUs)
        p.admissionUs = us(p.admissionUs)
        p.acceptedSentUs = us(p.acceptedSentUs)
        p.loadWaitStartUs = us(p.loadWaitStartUs)
        p.loadWaitEndUs = us(p.loadWaitEndUs)
        p.taskSpawnedUs = us(p.taskSpawnedUs)
        p.promptPrepStartUs = us(p.promptPrepStartUs)
        p.promptPrepEndUs = us(p.promptPrepEndUs)
        p.engineSubmitUs = us(p.engineSubmitUs)
        p.engineAdmittedUs = us(p.engineAdmittedUs)
        p.firstDeltaUs = us(p.firstDeltaUs)
        p.firstFrameUs = us(p.firstFrameUs)
        p.lastDeltaUs = us(p.lastDeltaUs)
        p.terminalBuiltUs = us(p.terminalBuiltUs)
        p.terminalSentUs = us(p.terminalSentUs)
        p.cancelReceivedUs = us(p.cancelReceivedUs)
        p.cancelAbortedUs = us(p.cancelAbortedUs)
        p.totalUs = us(p.totalUs)
        p.toolConstraintUs = us(p.toolConstraintUs)
        p.visionPrepUs = us(p.visionPrepUs)
        p.ssdStageUs = us(p.ssdStageUs)
        p.kvReserveUs = us(p.kvReserveUs)
        p.flushUs = us(p.flushUs)
        p.seSignUs = us(p.seSignUs)
        p.sleptUs = us(p.sleptUs)
        p.projectedServiceUs = us(p.projectedServiceUs)
        p.budgetRemainingAtAdmitUs = us(p.budgetRemainingAtAdmitUs)
        p.promptTokens = n(p.promptTokens)
        p.framesEmitted = n(p.framesEmitted)
        p.runningAtAdmit = n(p.runningAtAdmit)
        p.waitingAtAdmit = n(p.waitingAtAdmit)
        p.queuedPrefillTokensAtAdmit = n(p.queuedPrefillTokensAtAdmit)
        p.stepsAtSubmit = n(p.stepsAtSubmit)
        p.stepsAtFinish = n(p.stepsAtFinish)
        p.projectedPrefillTokens = n(p.projectedPrefillTokens)
        p.projectedDecodeTokens = n(p.projectedDecodeTokens)
        p.partialPrefillCap = n(p.partialPrefillCap)
        p.tokensAfterCancel = n(p.tokensAfterCancel)
        p.bytesEmitted = b(p.bytesEmitted)
        p.kvBytesInUseAtAdmit = b(p.kvBytesInUseAtAdmit)
        p.kvBytesCapacity = b(p.kvBytesCapacity)
        p.mlxActiveBytesAtFinish = b(p.mlxActiveBytesAtFinish)
        p.mlxPeakBytes = b(p.mlxPeakBytes)
        p.engine = p.engine?.saturatedToWireRanges()
        return p
    }
}

extension EngineProfile {
    /// `_ns` ≤ 3.6e12, counts ≤ 1e9, negatives to 0 (see
    /// `InferenceProfile.saturatedToWireRanges`).
    public func saturatedToWireRanges() -> EngineProfile {
        @inline(__always) func ns(_ v: Int64?) -> Int64? { v.map { min(max(0, $0), InferenceProfile.maxWireNanos) } }
        @inline(__always) func n(_ v: Int64?) -> Int64? { v.map { min(max(0, $0), InferenceProfile.maxWireCount) } }
        var e = self
        e.admittedNs = ns(e.admittedNs)
        e.kvAllocatedNs = ns(e.kvAllocatedNs)
        e.prefillFirstLaunchNs = ns(e.prefillFirstLaunchNs)
        e.promptComputedNs = ns(e.promptComputedNs)
        e.firstTokenNs = ns(e.firstTokenNs)
        e.finishedNs = ns(e.finishedNs)
        e.readmissions = n(e.readmissions)
        e.preemptions = n(e.preemptions)
        e.capacityRequeues = n(e.capacityRequeues)
        e.prefillChunks = n(e.prefillChunks)
        e.packedPrefillChunks = n(e.packedPrefillChunks)
        e.visionChunks = n(e.visionChunks)
        e.soloStripeChunks = n(e.soloStripeChunks)
        e.prefillChunkTokensMax = n(e.prefillChunkTokensMax)
        e.decodeSteps = n(e.decodeSteps)
        e.chainedDecodeSteps = n(e.chainedDecodeSteps)
        e.batchRowsSum = n(e.batchRowsSum)
        e.batchRowsMin = n(e.batchRowsMin)
        e.batchRowsMax = n(e.batchRowsMax)
        e.stepLatencyNsSum = ns(e.stepLatencyNsSum)
        e.stepLatencyNsMax = ns(e.stepLatencyNsMax)
        e.mtpRounds = n(e.mtpRounds)
        e.mtpProposed = n(e.mtpProposed)
        e.mtpAccepted = n(e.mtpAccepted)
        e.pausedNs = ns(e.pausedNs)
        e.pauseCount = n(e.pauseCount)
        e.detokDelayFirstNs = ns(e.detokDelayFirstNs)
        e.prefixLookupNs = ns(e.prefixLookupNs)
        e.prefixAdoptionNs = ns(e.prefixAdoptionNs)
        return e
    }
}

// MARK: - Heartbeat telemetry sub-objects

/// Per-slot engine posture the bridge can produce today. Presence of the
/// object (even sparse) is the "new provider" sentinel for the coordinator.
public struct SlotTelemetry: Codable, Sendable, Equatable {
    /// Σ `promptTokens` of requests whose `engine.submit` has not returned.
    public var queuedPrefillTokens: Int64?
    /// Admitted rows that have not produced a first token yet.
    public var partialPrefillRows: Int64?
    /// Cumulative Σ(prompt − cached) over finished requests (attributed at
    /// finish; see `EngineV2Bridge.recordFinish`).
    public var prefillTokensTotal: Int64?
    public var isolatedPrefillTps: Double?
    public var ewmaInitialized: Bool?
    public var pumpTasks: Int64?
    public var mtpRoundsTotal: Int64?
    public var mtpProposedTotal: Int64?
    public var mtpAcceptedTotal: Int64?
    public var kvBytesInUse: Int64?
    public var kvBytesCapacity: Int64?
    public var evalInFlightMs: Int64?
    /// Slice 3 producers (engine-side); omitted until then.
    public var stepWallNsTotal: Int64?
    public var decodeRowsTotal: Int64?

    enum CodingKeys: String, CodingKey {
        case queuedPrefillTokens = "queued_prefill_tokens"
        case partialPrefillRows = "partial_prefill_rows"
        case prefillTokensTotal = "prefill_tokens_total"
        case isolatedPrefillTps = "isolated_prefill_tps"
        case ewmaInitialized = "ewma_initialized"
        case pumpTasks = "pump_tasks"
        case mtpRoundsTotal = "mtp_rounds_total"
        case mtpProposedTotal = "mtp_proposed_total"
        case mtpAcceptedTotal = "mtp_accepted_total"
        case kvBytesInUse = "kv_bytes_in_use"
        case kvBytesCapacity = "kv_bytes_capacity"
        case evalInFlightMs = "eval_in_flight_ms"
        case stepWallNsTotal = "step_wall_ns_total"
        case decodeRowsTotal = "decode_rows_total"
    }

    public init(
        queuedPrefillTokens: Int64? = nil,
        partialPrefillRows: Int64? = nil,
        prefillTokensTotal: Int64? = nil,
        isolatedPrefillTps: Double? = nil,
        ewmaInitialized: Bool? = nil,
        pumpTasks: Int64? = nil,
        mtpRoundsTotal: Int64? = nil,
        mtpProposedTotal: Int64? = nil,
        mtpAcceptedTotal: Int64? = nil,
        kvBytesInUse: Int64? = nil,
        kvBytesCapacity: Int64? = nil,
        evalInFlightMs: Int64? = nil,
        stepWallNsTotal: Int64? = nil,
        decodeRowsTotal: Int64? = nil
    ) {
        self.queuedPrefillTokens = queuedPrefillTokens
        self.partialPrefillRows = partialPrefillRows
        self.prefillTokensTotal = prefillTokensTotal
        self.isolatedPrefillTps = isolatedPrefillTps
        self.ewmaInitialized = ewmaInitialized
        self.pumpTasks = pumpTasks
        self.mtpRoundsTotal = mtpRoundsTotal
        self.mtpProposedTotal = mtpProposedTotal
        self.mtpAcceptedTotal = mtpAcceptedTotal
        self.kvBytesInUse = kvBytesInUse
        self.kvBytesCapacity = kvBytesCapacity
        self.evalInFlightMs = evalInFlightMs
        self.stepWallNsTotal = stepWallNsTotal
        self.decodeRowsTotal = decodeRowsTotal
    }
}

/// Process-level posture on `BackendCapacity`.
public struct CapacityTelemetry: Codable, Sendable, Equatable {
    public var lowPowerMode: Bool?
    public var memoryPressureLevel: MemoryPressureLevelWire?
    public var mlxNumResources: Int64?
    /// Coordinator requests accepted but not yet finished (`requestToModel`).
    public var inAdmission: Int64?
    /// Detached inference tasks registered (`inflightTasks`).
    public var inflightTasks: Int64?

    enum CodingKeys: String, CodingKey {
        case lowPowerMode = "low_power_mode"
        case memoryPressureLevel = "memory_pressure_level"
        case mlxNumResources = "mlx_num_resources"
        case inAdmission = "in_admission"
        case inflightTasks = "inflight_tasks"
    }

    public init(
        lowPowerMode: Bool? = nil,
        memoryPressureLevel: MemoryPressureLevelWire? = nil,
        mlxNumResources: Int64? = nil,
        inAdmission: Int64? = nil,
        inflightTasks: Int64? = nil
    ) {
        self.lowPowerMode = lowPowerMode
        self.memoryPressureLevel = memoryPressureLevel
        self.mlxNumResources = mlxNumResources
        self.inAdmission = inAdmission
        self.inflightTasks = inflightTasks
    }
}
