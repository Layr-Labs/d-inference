import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Model-free: the prefix vote's keys computed from one joined prompt are the
// per-length keys byte for byte (so held entries keep matching).
@Suite("Tensor-parallel prefix keys from one joined prompt")
struct QwenTensorParallelPrefixKeysTests {
    @Test func keysAreTheKeys() {
        let prompt = (0 ..< 31_500).map { ($0 * 7919 + 13) % 154_880 }
        for lengths in [[4096, 8192, 28_672], [1], [31_499, 0], QwenTensorParallelPrefixCache.candidates(promptCount: 31_500, chunk: 4096)] {
            let keys = QwenTensorParallelPrefixCache.keys(scope: "scope|x", prompt: prompt, lengths: lengths)
            #expect(keys == lengths.map { QwenTensorParallelPrefixCache.key(scope: "scope|x", prompt: prompt, length: $0) })
        }
        #expect(QwenTensorParallelPrefixCache.keys(scope: "s", prompt: [], lengths: []) == [])
        #expect(QwenTensorParallelPrefixCache.keys(scope: "s", prompt: [5, 6], lengths: [2, 3])
            == [QwenTensorParallelPrefixCache.key(scope: "s", prompt: [5, 6], length: 2),
                QwenTensorParallelPrefixCache.key(scope: "s", prompt: [5, 6], length: 3)])
    }
}
