import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite("Native diffusion exact boundary identities")
struct NativeDiffusionCheckpointKeysTests {
    private let contract = String(repeating: "a", count: 64)
    private func reference(_ tokens: ArraySlice<Int>, contract: String, scope: String) -> Data {
        var bytes = Data("darkbloom.diffusion-native-prefix.v1".utf8)
        for text in [contract, scope] {
            let value = Data(text.utf8)
            var count = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        for token in tokens {
            var word = UInt32(token).bigEndian
            withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
        }
        return Data(SHA256.hash(data: bytes))
    }

    @Test func streamingKeysMatchIndependentPrefixEncodingAndAppends() throws {
        let tokens = (0..<1600).map { $0 % 137 }
        let positions = [276, 788, 1300, 1503]
        let hashes = try NativeDiffusionCheckpointKeys.hashes(tokens: tokens, positions: positions,
            promptContractID: contract, scope: "tenant-雪")
        for position in positions {
            #expect(hashes[position] == reference(tokens.prefix(position), contract: contract, scope: "tenant-雪"))
            #expect(try NativeDiffusionCheckpointKeys.hashes(tokens: tokens, positions: [position],
                promptContractID: contract, scope: "tenant-雪")[position] == hashes[position])
        }
        #expect(try NativeDiffusionCheckpointKeys.hashes(tokens: tokens + [19, 23], positions: positions,
            promptContractID: contract, scope: "tenant-雪") == hashes)
        var changed = tokens; changed[1300] = 139
        let changedHashes = try NativeDiffusionCheckpointKeys.hashes(tokens: changed, positions: positions,
            promptContractID: contract, scope: "tenant-雪")
        #expect(changedHashes[1300] == hashes[1300] && changedHashes[1503] != hashes[1503])
        for (otherContract, scope) in [(contract, "another-tenant"), (String(repeating: "b", count: 64), "tenant-雪")] {
            let other = try NativeDiffusionCheckpointKeys.hashes(tokens: tokens, positions: positions,
                promptContractID: otherContract, scope: scope)
            #expect(positions.allSatisfy { hashes[$0] != other[$0] })
        }
    }

    @Test func invalidPositionsAndTokensCannotAliasAValidPrefix() throws {
        for positions in [[0], [-1], [3], [1, 1], [2, 1]] {
            #expect(throws: NativeDiffusionCheckpointKeys.Failure.self) {
                try NativeDiffusionCheckpointKeys.hashes(tokens: [1, 2], positions: positions,
                    promptContractID: contract, scope: "tenant")
            }
        }
        for tokens in [[-1, 2], [Int(Int32.max) + 1, 2]] {
            #expect(throws: NativeDiffusionCheckpointKeys.Failure.self) {
                try NativeDiffusionCheckpointKeys.hashes(tokens: tokens, positions: [1],
                    promptContractID: contract, scope: "tenant")
            }
        }
        #expect(throws: NativeDiffusionCheckpointKeys.Failure.self) {
            try NativeDiffusionCheckpointKeys.hashes(tokens: [1], positions: [1], promptContractID: contract, scope: "")
        }
        #expect(try NativeDiffusionCheckpointKeys.hashes(tokens: [Int(Int32.max)], positions: [1],
            promptContractID: contract, scope: "tenant")[1] != nil)
        #expect(try NativeDiffusionCheckpointKeys.hashes(tokens: [], positions: [],
            promptContractID: contract, scope: "tenant").isEmpty)
    }
}
