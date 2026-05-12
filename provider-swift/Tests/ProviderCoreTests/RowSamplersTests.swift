// Unit tests for `makeRowSampler` (per-row sampler factory).
//
// These exercise the sampler in isolation -- no model, no `BatchGenerator` --
// so they run fast and are safe to keep in the default suite (no live MLX
// gating needed since we only build small `MLXArray` logits inline).

import Foundation
import MLX
import MLXLMCommon
import Testing

@Suite("RowSamplers")
struct RowSamplersTests {

    init() {
        // MLX kernels (argSort/softmax/categorical) need `mlx.metallib`
        // colocated with the test runner; the fixture copies it next to
        // the .xctest binary on first call. If unavailable, sampling
        // calls below will fall back to CPU paths or fail loudly.
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    // MARK: greedy passthrough

    @Test("temperature == 0 returns the greedy argmax")
    func greedyAtZeroTemperature() throws {
        let sampler = makeRowSampler(temperature: 0.0)
        // Logits where index 7 wins.
        var raw: [Float] = Array(repeating: -10.0, count: 16)
        raw[7] = 5.0
        let logits = MLXArray(raw).reshaped([1, 16])

        let token = sampler(logits).asArray(Int32.self).first.map(Int.init)
        #expect(token == 7)
    }

    // MARK: top-K

    @Test("topK == 1 always picks the argmax")
    func topKOneIsArgmax() throws {
        // Even with temperature, top-K=1 should be deterministic.
        let sampler = makeRowSampler(temperature: 1.0, topK: 1, seed: 42)
        var raw: [Float] = Array(repeating: 0.0, count: 32)
        raw[12] = 100.0
        let logits = MLXArray(raw).reshaped([1, 32])

        for _ in 0 ..< 10 {
            let token = sampler(logits).asArray(Int32.self).first.map(Int.init)
            #expect(token == 12, "top-K=1 must be deterministic argmax")
        }
    }

    @Test("topK only samples within the top-K set")
    func topKLimitsTokenSet() throws {
        // Seed a heavy-tailed distribution: 4 large logits, rest tiny.
        var raw: [Float] = Array(repeating: -100.0, count: 64)
        raw[3] = 5.0
        raw[10] = 4.5
        raw[20] = 4.0
        raw[42] = 3.5
        // Several other "tail" tokens that should be masked out.
        raw[0] = 1.0
        raw[63] = 0.5
        let logits = MLXArray(raw).reshaped([1, 64])

        let allowed: Set<Int> = [3, 10, 20, 42]
        let sampler = makeRowSampler(temperature: 1.0, topK: 4, seed: 7)
        for _ in 0 ..< 50 {
            let token = sampler(logits).asArray(Int32.self).first.map(Int.init)!
            #expect(allowed.contains(token), "sampled token \(token) outside top-K \(allowed)")
        }
    }

    // MARK: top-P (nucleus)

    @Test("topP == 0.5 keeps only the dominant token when one mass dwarfs the rest")
    func topPDominantToken() throws {
        // Token 4 carries ~all the softmax mass.
        var raw: [Float] = Array(repeating: 0.0, count: 16)
        raw[4] = 50.0
        let logits = MLXArray(raw).reshaped([1, 16])

        let sampler = makeRowSampler(temperature: 1.0, topP: 0.5, seed: 99)
        for _ in 0 ..< 25 {
            let token = sampler(logits).asArray(Int32.self).first.map(Int.init)
            #expect(token == 4, "nucleus should collapse to the dominant token")
        }
    }

    @Test("topP == 1.0 is a no-op (all tokens reachable given enough draws)")
    func topPOneIsIdentity() throws {
        // Uniform logits except a slight bias toward two tokens.
        var raw: [Float] = Array(repeating: 0.0, count: 8)
        raw[1] = 0.05
        raw[5] = 0.05
        let logits = MLXArray(raw).reshaped([1, 8])

        let sampler = makeRowSampler(temperature: 1.0, topP: 1.0, seed: 1)
        var seen: Set<Int> = []
        for _ in 0 ..< 200 {
            let token = sampler(logits).asArray(Int32.self).first.map(Int.init)!
            seen.insert(token)
        }
        // We should see at least 4 of the 8 tokens with topP=1.
        #expect(seen.count >= 4, "expected diverse draws under topP=1, saw \(seen)")
    }

    // MARK: seeded determinism

    @Test("same seed produces the same sequence of draws")
    func seededDeterminism() throws {
        let raw: [Float] = (0 ..< 32).map { Float($0) * 0.1 }
        let logits = MLXArray(raw).reshaped([1, 32])

        let s1 = makeRowSampler(temperature: 0.8, topP: 0.9, topK: 8, seed: 12345)
        let s2 = makeRowSampler(temperature: 0.8, topP: 0.9, topK: 8, seed: 12345)

        var draws1: [Int] = []
        var draws2: [Int] = []
        for _ in 0 ..< 16 {
            draws1.append(Int(s1(logits).asArray(Int32.self).first ?? -1))
            draws2.append(Int(s2(logits).asArray(Int32.self).first ?? -1))
        }

        #expect(draws1 == draws2, "same seed must yield same sequence")
        // And the sequence should not be all-identical (otherwise the seed
        // isn't actually advancing).
        #expect(Set(draws1).count > 1, "seed advancement should produce variety")
    }

    @Test("different seeds produce different sequences")
    func differentSeedsDiverge() throws {
        let raw: [Float] = (0 ..< 32).map { Float($0) * 0.1 }
        let logits = MLXArray(raw).reshaped([1, 32])

        let s1 = makeRowSampler(temperature: 0.8, topK: 8, seed: 1)
        let s2 = makeRowSampler(temperature: 0.8, topK: 8, seed: 2)

        var draws1: [Int] = []
        var draws2: [Int] = []
        for _ in 0 ..< 16 {
            draws1.append(Int(s1(logits).asArray(Int32.self).first ?? -1))
            draws2.append(Int(s2(logits).asArray(Int32.self).first ?? -1))
        }

        #expect(draws1 != draws2, "different seeds should diverge")
    }
}
