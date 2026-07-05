import Foundation

// Engine-facing KV-quantization candidate descriptor.
//
// `KVQuantCandidateMode` is the concrete scheme string (bit width, group size,
// start token, dequant vs kernel) that the live continuous-batching scheduler
// resolves through `KVQuantEngineScheme` and that the benchmark/gate tooling
// parses from the CLI. It lives in ProviderCore (not the benchmark target)
// because `BatchScheduler` depends on it on the live decode path; the benchmark
// runners consume it from here.

public enum KVQuantCandidateMode: String, CaseIterable, Codable, Sendable, CustomStringConvertible {
    case fp16KV = "fp16-kv"
    case bf16KV = "bf16-kv:start1024"
    case fullVBF16 = "full-v-bf16:start1024"
    case affine4 = "affine4:g64:start1024"
    case affine8 = "affine8:g64:start1024"
    case fullVAffine4 = "full-v-affine4:g64:start1024"
    case fullVTurbo4 = "full-v-turbo4:start1024"
    case fullKVTurbo4 = "full-kv-turbo4:start1024"
    case turbo4v2 = "turbo4v2:start1024"
    case k8v8g128 = "k8v8:g128"
    case k8v8g64 = "k8v8:g64"
    case k8v8g64Dequant = "k8v8:g64:dequant"
    case k6v6g64 = "k6v6:g64"
    case k6v6g64Dequant = "k6v6:g64:dequant"

    public var description: String { rawValue }

    public var label: String { rawValue }

    public var isReference: Bool { self == .fp16KV }

    public var bitWidth: Int? {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: nil
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    public var groupSize: Int? {
        switch self {
        case .affine4, .affine8, .fullVAffine4, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: 64
        case .k8v8g128: 128
        case .fp16KV, .bf16KV, .fullVBF16, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: nil
        }
    }

    public var startToken: Int? {
        switch self {
        case .fp16KV: nil
        case .bf16KV, .fullVBF16, .affine4, .affine8, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 1024
        case .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: 0
        }
    }

    public var quantizesKeys: Bool {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16, .fullVAffine4, .fullVTurbo4: false
        case .affine4, .affine8, .fullKVTurbo4, .turbo4v2, .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: true
        }
    }

    public var quantizesValues: Bool {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: false
        case .affine4, .affine8, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2, .k8v8g128, .k8v8g64, .k8v8g64Dequant, .k6v6g64, .k6v6g64Dequant: true
        }
    }

    /// Stored bits-per-element for KEYS on the context-growing (full/global)
    /// attention layers. bf16 is 16 bits — same bytes as fp16 — so it yields NO
    /// capacity gain; this metric makes that explicit.
    public var storedBitsK: Int {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16, .fullVAffine4, .fullVTurbo4: 16
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    /// Stored bits-per-element for VALUES on the context-growing layers.
    /// Note: bf16 is 16 bits (2 bytes) — same as fp16 — so `fullVBF16` yields no
    /// capacity gain, which the capacity metric must reflect honestly.
    public var storedBitsV: Int {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16: 16
        case .affine8, .k8v8g128, .k8v8g64, .k8v8g64Dequant: 8
        case .k6v6g64, .k6v6g64Dequant: 6
        case .affine4, .fullVAffine4, .fullVTurbo4, .fullKVTurbo4, .turbo4v2: 4
        }
    }

    /// Effective stored bits-per-element including affine scale+bias overhead
    /// (two fp16 values per quantization group). 16-bit (fp16/bf16) has no group
    /// overhead; sub-16-bit modes use their configured group size.
    private func effectiveBits(_ bits: Int) -> Double {
        guard bits < 16 else { return 16.0 }
        let group = Double(groupSize ?? 64)
        return Double(bits) + 32.0 / group  // + fp16 scale + fp16 bias per group
    }

    /// Effective KV bytes per token-per-(growing)-layer for the context-growing
    /// (full/global) attention layers, expressed per element of n_kv_heads*head_dim
    /// (so it's model-shape independent). Baseline fp16 K+V = 4.0 bytes/elem.
    public var effectiveKVBytesPerTokenPerElem: Double {
        (effectiveBits(storedBitsK) + effectiveBits(storedBitsV)) / 8.0
    }

    /// Headline capacity multiplier: how many more tokens can be admitted at fixed
    /// RAM vs fp16 (max-admitted-tokens scales ~linearly with this, weights aside).
    public var capacityRatioVsFP16: Double {
        let fp16Bytes = (16.0 + 16.0) / 8.0
        return fp16Bytes / max(effectiveKVBytesPerTokenPerElem, 1e-9)
    }

    public init?(parsing rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static func parse(_ rawValue: String) throws -> KVQuantCandidateMode {
        guard let mode = KVQuantCandidateMode(rawValue: rawValue) else {
            throw KVQuantCandidateModeParseError(rawValue: rawValue)
        }
        return mode
    }
}

public struct KVQuantCandidateModeParseError: Error, LocalizedError, Sendable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var errorDescription: String? {
        let allowed = KVQuantCandidateMode.allCases.map(\.rawValue).joined(separator: ", ")
        return "unknown KV quant mode '\(rawValue)'; expected one of: \(allowed)"
    }
}
