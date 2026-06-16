import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Test("KV quant candidate modes parse from their raw labels")
func kvQuantCandidateModesParseFromRawLabels() throws {
    #expect(try KVQuantCandidateMode.parse("fp16-kv") == .fp16KV)
    #expect(try KVQuantCandidateMode.parse("bf16-kv:start1024") == .bf16KV)
    #expect(try KVQuantCandidateMode.parse("full-v-bf16:start1024") == .fullVBF16)
    #expect(try KVQuantCandidateMode.parse("affine4:g64:start1024") == .affine4)
    #expect(try KVQuantCandidateMode.parse("affine8:g64:start1024") == .affine8)
    #expect(try KVQuantCandidateMode.parse("full-v-affine4:g64:start1024") == .fullVAffine4)
    #expect(try KVQuantCandidateMode.parse("k8v8:g128") == .k8v8g128)
    #expect(try KVQuantCandidateMode.parse("k8v8:g64:dequant") == .k8v8g64Dequant)
    #expect(try KVQuantCandidateMode.parse("k6v6:g64") == .k6v6g64)
    #expect(try KVQuantCandidateMode.parse("k6v6:g64:dequant") == .k6v6g64Dequant)
}

@Test("KV quant mode parsing rejects unknown labels")
func kvQuantCandidateModeParsingRejectsUnknownLabels() {
    #expect(throws: KVQuantCandidateModeParseError.self) {
        try KVQuantCandidateMode.parse("not-a-mode")
    }
}

@Test("fp16 KV mode uses no quantization parameters")
func fp16KVExecutionConfigUsesNoQuantization() throws {
    let config = try KVQuantExecution.config(for: .fp16KV)

    #expect(config.parameters.kvBits == nil)
    #expect(config.parameters.kvGroupSize == 64)
    #expect(config.parameters.quantizedKVStart == 0)
    #expect(config.cacheFactory == nil)
}

@Test("affine4 full-KV mode supplies a protocol-safe quantized cache factory")
func affine4FullKVModeSuppliesProtocolSafeQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .affine4)

    #expect(config.parameters.kvBits == nil)
    #expect(config.parameters.kvGroupSize == 64)
    #expect(config.parameters.quantizedKVStart == 0)
    #expect(config.cacheFactory != nil)
}

@Test("affine8 full-KV mode supplies a protocol-safe quantized cache factory")
func affine8FullKVModeSuppliesProtocolSafeQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .affine8)

    #expect(config.parameters.kvBits == nil)
    #expect(config.parameters.kvGroupSize == 64)
    #expect(config.parameters.quantizedKVStart == 0)
    #expect(config.cacheFactory != nil)
}

@Test("bf16-kv mode supplies a bfloat16 cache factory")
func bf16KVModeSuppliesBFloat16CacheFactory() throws {
    let config = try KVQuantExecution.config(for: .bf16KV)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("k8v8:g128 mode supplies a protocol-safe quantized cache factory")
func k8v8g128ModeSuppliesProtocolSafeQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .k8v8g128)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("k8v8:g64:dequant mode supplies a dequantizing quantized cache factory")
func k8v8g64DequantModeSuppliesDequantizingQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .k8v8g64Dequant)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("k6v6:g64 mode supplies a protocol-safe quantized cache factory")
func k6v6g64ModeSuppliesProtocolSafeQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .k6v6g64)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("k6v6:g64:dequant mode supplies a dequantizing quantized cache factory")
func k6v6g64DequantModeSuppliesDequantizingQuantizedCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .k6v6g64Dequant)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("full-v-bf16 mode supplies a V-only bfloat16 cache factory")
func fullVBF16ModeSuppliesVOnlyBFloat16CacheFactory() throws {
    let config = try KVQuantExecution.config(for: .fullVBF16)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("full-v-affine4 mode supplies a V-only quantized cache factory")
func fullVAffine4ModeSuppliesVOnlyCacheFactory() throws {
    let config = try KVQuantExecution.config(for: .fullVAffine4)

    #expect(config.parameters.kvBits == nil)
    #expect(config.cacheFactory != nil)
}

@Test("Unsupported turbo KV modes are rejected with a clear error")
func unsupportedTurboModesAreRejected() throws {
    for mode in [KVQuantCandidateMode.fullVTurbo4, .fullKVTurbo4, .turbo4v2] {
        #expect(throws: KVQuantExecutionError.unsupportedMode(mode.rawValue)) {
            try KVQuantExecution.config(for: mode)
        }
    }
}
