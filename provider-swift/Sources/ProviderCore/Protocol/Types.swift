import Foundation

/// Well-known error reason attached to inference / load_model / prefetch_model
/// rejections while the provider is draining ahead of an auto-update restart.
/// The coordinator matches this exact string to treat a load_model failure as
/// transient (short retry backoff, provider is about to restart) rather than a
/// genuine load failure. Mirrored in coordinator/protocol/messages.go
/// (ProviderDrainingForUpdate) — keep the two in sync.
public let providerDrainingForUpdateReason = "provider draining for update"

public struct HardwareInfo: Codable, Sendable, Equatable {
    public var machineModel: String
    public var chipName: String
    public var chipFamily: ChipFamily
    public var chipTier: ChipTier
    public var memoryGb: UInt64
    public var memoryAvailableGb: UInt64
    public var cpuCores: CpuCores
    public var gpuCores: UInt32
    public var memoryBandwidthGbs: UInt32

    enum CodingKeys: String, CodingKey {
        case machineModel = "machine_model"
        case chipName = "chip_name"
        case chipFamily = "chip_family"
        case chipTier = "chip_tier"
        case memoryGb = "memory_gb"
        case memoryAvailableGb = "memory_available_gb"
        case cpuCores = "cpu_cores"
        case gpuCores = "gpu_cores"
        case memoryBandwidthGbs = "memory_bandwidth_gbs"
    }

    public init(
        machineModel: String,
        chipName: String,
        chipFamily: ChipFamily,
        chipTier: ChipTier,
        memoryGb: UInt64,
        memoryAvailableGb: UInt64,
        cpuCores: CpuCores,
        gpuCores: UInt32,
        memoryBandwidthGbs: UInt32
    ) {
        self.machineModel = machineModel
        self.chipName = chipName
        self.chipFamily = chipFamily
        self.chipTier = chipTier
        self.memoryGb = memoryGb
        self.memoryAvailableGb = memoryAvailableGb
        self.cpuCores = cpuCores
        self.gpuCores = gpuCores
        self.memoryBandwidthGbs = memoryBandwidthGbs
    }
}

public struct CpuCores: Codable, Sendable, Equatable {
    public var total: UInt32
    public var performance: UInt32
    public var efficiency: UInt32

    public init(total: UInt32, performance: UInt32, efficiency: UInt32) {
        self.total = total
        self.performance = performance
        self.efficiency = efficiency
    }
}

public struct SystemMetrics: Codable, Sendable, Equatable {
    public var memoryPressure: Double
    public var cpuUsage: Double
    public var thermalState: ThermalState

    enum CodingKeys: String, CodingKey {
        case memoryPressure = "memory_pressure"
        case cpuUsage = "cpu_usage"
        case thermalState = "thermal_state"
    }

    public init(memoryPressure: Double, cpuUsage: Double, thermalState: ThermalState) {
        self.memoryPressure = memoryPressure
        self.cpuUsage = cpuUsage
        self.thermalState = thermalState
    }
}

public struct ModelInfo: Codable, Sendable, Equatable {
    public var id: String
    public var modelType: String?
    public var parameters: UInt64?
    public var quantization: String?
    public var sizeBytes: UInt64
    public var estimatedMemoryGb: Double
    public var weightHash: String?
    /// True when this build can serve image/video (VLM) input. Encoded only when
    /// true (matches the coordinator's `is_vision,omitempty`), so pre-0.6.0
    /// providers and text-only builds omit it and are never routed media requests.
    public var isVision: Bool?
    /// Tri-state template-render self-check result (DAR-130 class): the scanner
    /// renders the model's chat template(s) against canonical request fixtures
    /// (`TemplateRenderCheck`). nil = no template found / check didn't run
    /// (key omitted on the wire, matching old providers); true = every fixture
    /// rendered; false = some fixture threw — the coordinator uses false to
    /// refuse routing tool-bearing requests to this (provider, model). Unlike
    /// `isVision`, FALSE IS THE SIGNAL and must go on the wire.
    public var templateRenderOK: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case modelType = "model_type"
        case parameters
        case quantization
        case sizeBytes = "size_bytes"
        case estimatedMemoryGb = "estimated_memory_gb"
        case weightHash = "weight_hash"
        case isVision = "is_vision"
        case templateRenderOK = "template_render_ok"
    }

    public init(
        id: String,
        modelType: String? = nil,
        parameters: UInt64? = nil,
        quantization: String? = nil,
        sizeBytes: UInt64,
        estimatedMemoryGb: Double,
        weightHash: String? = nil,
        isVision: Bool? = nil,
        templateRenderOK: Bool? = nil
    ) {
        self.id = id
        self.modelType = modelType
        self.parameters = parameters
        self.quantization = quantization
        self.sizeBytes = sizeBytes
        self.estimatedMemoryGb = estimatedMemoryGb
        self.weightHash = weightHash
        self.isVision = isVision
        self.templateRenderOK = templateRenderOK
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(modelType, forKey: .modelType)
        try container.encodeIfPresent(parameters, forKey: .parameters)
        try container.encodeIfPresent(quantization, forKey: .quantization)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(estimatedMemoryGb, forKey: .estimatedMemoryGb)
        try container.encodeIfPresent(weightHash, forKey: .weightHash)
        // Encode only when true so text-only builds stay byte-compatible on the wire.
        if isVision == true {
            try container.encode(true, forKey: .isVision)
        }
        // Tri-state: encode BOTH true and false when the check ran — false is
        // the broken-template routing signal. Omit only when unknown (nil), so
        // the coordinator can distinguish "check didn't run" from "passed".
        try container.encodeIfPresent(templateRenderOK, forKey: .templateRenderOK)
    }
}

public struct ProviderStats: Codable, Sendable, Equatable {
    public var requestsServed: UInt64
    public var tokensGenerated: UInt64

    enum CodingKeys: String, CodingKey {
        case requestsServed = "requests_served"
        case tokensGenerated = "tokens_generated"
    }

    public init(requestsServed: UInt64 = 0, tokensGenerated: UInt64 = 0) {
        self.requestsServed = requestsServed
        self.tokensGenerated = tokensGenerated
    }
}

public struct UsageInfo: Codable, Sendable, Equatable {
    public var promptTokens: UInt64
    public var completionTokens: UInt64
    /// Subset of `completionTokens` spent on reasoning/analysis content
    /// (gpt-oss analysis channel, <think> blocks, etc.). Counted with the
    /// model tokenizer on the provider; 0 when the response carried no
    /// reasoning content. The coordinator surfaces this as
    /// `reasoning_tokens` in the Responses API and as
    /// `completion_tokens_details.reasoning_tokens` in chat completions.
    public var reasoningTokens: UInt64

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case reasoningTokens = "reasoning_tokens"
    }

    public init(promptTokens: UInt64, completionTokens: UInt64, reasoningTokens: UInt64 = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promptTokens = try c.decode(UInt64.self, forKey: .promptTokens)
        self.completionTokens = try c.decode(UInt64.self, forKey: .completionTokens)
        // Optional for backward compatibility with peers that don't send it.
        self.reasoningTokens = try c.decodeIfPresent(UInt64.self, forKey: .reasoningTokens) ?? 0
    }
}

public struct EncryptedPayload: Codable, Sendable, Equatable {
    public var ephemeralPublicKey: String
    public var ciphertext: String

    enum CodingKeys: String, CodingKey {
        case ephemeralPublicKey = "ephemeral_public_key"
        case ciphertext
    }

    public init(ephemeralPublicKey: String, ciphertext: String) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ciphertext = ciphertext
    }
}

public struct PrivacyCapabilities: Codable, Sendable, Equatable {
    public var textBackendInprocess: Bool
    public var textProxyDisabled: Bool
    public var pythonRuntimeLocked: Bool
    public var dangerousModulesBlocked: Bool
    public var sipEnabled: Bool
    public var antiDebugEnabled: Bool
    public var coreDumpsDisabled: Bool
    public var envScrubbed: Bool
    public var hypervisorActive: Bool

    enum CodingKeys: String, CodingKey {
        case textBackendInprocess = "text_backend_inprocess"
        case textProxyDisabled = "text_proxy_disabled"
        case pythonRuntimeLocked = "python_runtime_locked"
        case dangerousModulesBlocked = "dangerous_modules_blocked"
        case sipEnabled = "sip_enabled"
        case antiDebugEnabled = "anti_debug_enabled"
        case coreDumpsDisabled = "core_dumps_disabled"
        case envScrubbed = "env_scrubbed"
        case hypervisorActive = "hypervisor_active"
    }

    public init(
        textBackendInprocess: Bool,
        textProxyDisabled: Bool,
        pythonRuntimeLocked: Bool,
        dangerousModulesBlocked: Bool,
        sipEnabled: Bool,
        antiDebugEnabled: Bool,
        coreDumpsDisabled: Bool,
        envScrubbed: Bool,
        hypervisorActive: Bool = false
    ) {
        self.textBackendInprocess = textBackendInprocess
        self.textProxyDisabled = textProxyDisabled
        self.pythonRuntimeLocked = pythonRuntimeLocked
        self.dangerousModulesBlocked = dangerousModulesBlocked
        self.sipEnabled = sipEnabled
        self.antiDebugEnabled = antiDebugEnabled
        self.coreDumpsDisabled = coreDumpsDisabled
        self.envScrubbed = envScrubbed
        self.hypervisorActive = hypervisorActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textBackendInprocess = try container.decode(Bool.self, forKey: .textBackendInprocess)
        textProxyDisabled = try container.decode(Bool.self, forKey: .textProxyDisabled)
        pythonRuntimeLocked = try container.decode(Bool.self, forKey: .pythonRuntimeLocked)
        dangerousModulesBlocked = try container.decode(Bool.self, forKey: .dangerousModulesBlocked)
        sipEnabled = try container.decode(Bool.self, forKey: .sipEnabled)
        antiDebugEnabled = try container.decode(Bool.self, forKey: .antiDebugEnabled)
        coreDumpsDisabled = try container.decode(Bool.self, forKey: .coreDumpsDisabled)
        envScrubbed = try container.decode(Bool.self, forKey: .envScrubbed)
        hypervisorActive = try container.decodeIfPresent(Bool.self, forKey: .hypervisorActive) ?? false
    }
}

public struct RuntimeMismatch: Codable, Sendable, Equatable {
    public var component: String
    public var expected: String
    public var got: String

    public init(component: String, expected: String, got: String) {
        self.component = component
        self.expected = expected
        self.got = got
    }
}

public struct BackendSlotCapacity: Codable, Sendable, Equatable {
    public var model: String
    public var state: String
    public var numRunning: UInt32
    public var numWaiting: UInt32
    public var activeTokens: Int64
    public var maxTokensPotential: Int64
    public var observedDecodeTps: Double
    public var activeTokenBudgetUsed: Int64
    public var activeTokenBudgetMax: Int64
    public var queuedTokenBudget: Int64
    public var kvBytesPerToken: Int64
    public var maxConcurrency: UInt32

    enum CodingKeys: String, CodingKey {
        case model
        case state
        case numRunning = "num_running"
        case numWaiting = "num_waiting"
        case activeTokens = "active_tokens"
        case maxTokensPotential = "max_tokens_potential"
        case observedDecodeTps = "observed_decode_tps"
        case activeTokenBudgetUsed = "active_token_budget_used"
        case activeTokenBudgetMax = "active_token_budget_max"
        case queuedTokenBudget = "queued_token_budget"
        case kvBytesPerToken = "kv_bytes_per_token"
        case maxConcurrency = "max_concurrency"
    }

    public init(
        model: String,
        state: String,
        numRunning: UInt32,
        numWaiting: UInt32,
        activeTokens: Int64,
        maxTokensPotential: Int64,
        maxConcurrency: UInt32 = 0,
        observedDecodeTps: Double = 0,
        activeTokenBudgetUsed: Int64 = 0,
        activeTokenBudgetMax: Int64 = 0,
        queuedTokenBudget: Int64 = 0,
        kvBytesPerToken: Int64 = 0
    ) {
        self.model = model
        self.state = state
        self.numRunning = numRunning
        self.numWaiting = numWaiting
        self.activeTokens = activeTokens
        self.maxTokensPotential = maxTokensPotential
        self.maxConcurrency = maxConcurrency
        self.observedDecodeTps = observedDecodeTps
        self.activeTokenBudgetUsed = activeTokenBudgetUsed
        self.activeTokenBudgetMax = activeTokenBudgetMax
        self.queuedTokenBudget = queuedTokenBudget
        self.kvBytesPerToken = kvBytesPerToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        state = try container.decode(String.self, forKey: .state)
        numRunning = try container.decode(UInt32.self, forKey: .numRunning)
        numWaiting = try container.decode(UInt32.self, forKey: .numWaiting)
        activeTokens = try container.decodeIfPresent(Int64.self, forKey: .activeTokens) ?? 0
        maxTokensPotential = try container.decodeIfPresent(Int64.self, forKey: .maxTokensPotential) ?? 0
        maxConcurrency = try container.decodeIfPresent(UInt32.self, forKey: .maxConcurrency) ?? 0
        observedDecodeTps = try container.decodeIfPresent(Double.self, forKey: .observedDecodeTps) ?? 0
        activeTokenBudgetUsed = try container.decodeIfPresent(Int64.self, forKey: .activeTokenBudgetUsed) ?? 0
        activeTokenBudgetMax = try container.decodeIfPresent(Int64.self, forKey: .activeTokenBudgetMax) ?? 0
        queuedTokenBudget = try container.decodeIfPresent(Int64.self, forKey: .queuedTokenBudget) ?? 0
        kvBytesPerToken = try container.decodeIfPresent(Int64.self, forKey: .kvBytesPerToken) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(state, forKey: .state)
        try container.encode(numRunning, forKey: .numRunning)
        try container.encode(numWaiting, forKey: .numWaiting)
        try container.encode(activeTokens, forKey: .activeTokens)
        try container.encode(maxTokensPotential, forKey: .maxTokensPotential)
        try encodeIfNonZero(maxConcurrency, forKey: .maxConcurrency, into: &container)
        try encodeIfNonZero(observedDecodeTps, forKey: .observedDecodeTps, into: &container)
        try encodeIfNonZero(activeTokenBudgetUsed, forKey: .activeTokenBudgetUsed, into: &container)
        try encodeIfNonZero(activeTokenBudgetMax, forKey: .activeTokenBudgetMax, into: &container)
        try encodeIfNonZero(queuedTokenBudget, forKey: .queuedTokenBudget, into: &container)
        try encodeIfNonZero(kvBytesPerToken, forKey: .kvBytesPerToken, into: &container)
    }

    private func encodeIfNonZero<T: BinaryInteger & Encodable>(
        _ value: T,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if value != 0 {
            try container.encode(value, forKey: key)
        }
    }

    private func encodeIfNonZero(
        _ value: Double,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if value != 0 {
            try container.encode(value, forKey: key)
        }
    }
}

public struct BackendCapacity: Codable, Sendable, Equatable {
    public var slots: [BackendSlotCapacity]
    public var gpuMemoryActiveGb: Double
    public var gpuMemoryPeakGb: Double
    public var gpuMemoryCacheGb: Double
    public var totalMemoryGb: Double

    enum CodingKeys: String, CodingKey {
        case slots
        case gpuMemoryActiveGb = "gpu_memory_active_gb"
        case gpuMemoryPeakGb = "gpu_memory_peak_gb"
        case gpuMemoryCacheGb = "gpu_memory_cache_gb"
        case totalMemoryGb = "total_memory_gb"
    }

    public init(
        slots: [BackendSlotCapacity],
        gpuMemoryActiveGb: Double,
        gpuMemoryPeakGb: Double,
        gpuMemoryCacheGb: Double,
        totalMemoryGb: Double
    ) {
        self.slots = slots
        self.gpuMemoryActiveGb = gpuMemoryActiveGb
        self.gpuMemoryPeakGb = gpuMemoryPeakGb
        self.gpuMemoryCacheGb = gpuMemoryCacheGb
        self.totalMemoryGb = totalMemoryGb
    }
}

/// Opaque JSON blob preserved as raw bytes for signature verification.
/// The coordinator verifies the attestation signature against the exact bytes
/// produced by the Swift enclave CLI -- any re-encoding would break verification.
public struct RawJSON: Sendable, Equatable {
    public let rawBytes: Data

    public init(rawBytes: Data) {
        self.rawBytes = rawBytes
    }

    public var string: String {
        String(data: rawBytes, encoding: .utf8) ?? ""
    }
}

extension RawJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let jsonObject = try container.decode(JSONValue.self)
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject.toFoundation(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        self.rawBytes = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let jsonObject = try JSONSerialization.jsonObject(with: rawBytes)
        let value = JSONValue.fromFoundation(jsonObject)
        try container.encode(value)
    }
}

/// Minimal JSON value type for capturing arbitrary JSON without structure loss.
/// Used both for RawJSON (attestation blobs) and for the InferenceRequest body
/// field, which is an opaque JSON value on the wire.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (pair, other) in zip(a, b) {
                if pair.0 != other.0 || pair.1 != other.1 { return false }
            }
            return true
        default:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if var arr = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !arr.isAtEnd {
                values.append(try arr.decode(JSONValue.self))
            }
            self = .array(values)
        } else {
            let obj = try decoder.container(keyedBy: DynamicCodingKey.self)
            var pairs: [(String, JSONValue)] = []
            for key in obj.allKeys {
                pairs.append((key.stringValue, try obj.decode(JSONValue.self, forKey: key)))
            }
            self = .object(pairs)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let pairs):
            var obj = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in pairs {
                try obj.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }

    func toFoundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toFoundation() }
        case .object(let pairs):
            var dict: [String: Any] = [:]
            for (k, v) in pairs { dict[k] = v.toFoundation() }
            return dict
        }
    }

    static func fromFoundation(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let n as NSNumber:
            if CFNumberGetType(n) == .float32Type || CFNumberGetType(n) == .float64Type
                || CFNumberGetType(n) == .doubleType
            {
                return .double(n.doubleValue)
            }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map { fromFoundation($0) })
        case let dict as [String: Any]:
            return .object(
                dict.sorted(by: { $0.key < $1.key }).map { ($0.key, fromFoundation($0.value)) }
            )
        default:
            return .null
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
