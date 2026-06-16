import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

@Test("V-only bfloat16 cache stores values as bfloat16 after start token")
func vOnlyBFloat16CacheStoresValuesAsBFloat16() throws {
    let cache = VOnlyBFloat16KVCache(startToken: 0)
    let B = 1
    let nKVHeads = 4
    let numSteps = 8
    let headDim = 16

    let keys = MLXArray.zeros([B, nKVHeads, numSteps, headDim], dtype: .float16)
    let values = MLXArray.zeros([B, nKVHeads, numSteps, headDim], dtype: .float16)

    let (returnedKeys, returnedValues) = cache.update(keys: keys, values: values)

    #expect(returnedKeys.dtype == .float16)
    #expect(returnedValues.dtype == .bfloat16)
}

@Test("BFloat16 cache stores keys and values as bfloat16 after start token")
func bFloat16CacheStoresKeysAndValuesAsBFloat16() throws {
    let cache = BFloat16KVCache(startToken: 0)
    let B = 1
    let nKVHeads = 4
    let numSteps = 8
    let headDim = 16

    let keys = MLXArray.zeros([B, nKVHeads, numSteps, headDim], dtype: .float16)
    let values = MLXArray.zeros([B, nKVHeads, numSteps, headDim], dtype: .float16)

    let (returnedKeys, returnedValues) = cache.update(keys: keys, values: values)

    #expect(returnedKeys.dtype == .bfloat16)
    #expect(returnedValues.dtype == .bfloat16)
}
