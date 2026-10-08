import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    /// Computes only the chain needed by an aligned text checkpoint. The caller
    /// validates manifest/token structure before entering this helper. Original
    /// donor tokens preserve the backend's existing final-token rules; hashing
    /// only an aligned prefix would lose ordinary interior endpoints.
    ///
    /// Native diffusion media uses its separate exact-position hash contract.
    func donationHashes(tokens: [Int], scope: String, checkpointPosition: Int) -> [Data]? {
        guard checkpointPosition > 0,
            checkpointPosition.isMultiple(of: PrefixCachePolicy.blockSize),
            checkpointPosition <= tokens.count
        else { return nil }
        let blocks = checkpointPosition / PrefixCachePolicy.blockSize
        let chain = hashes(tokens: tokens, scope: scope, maximumBlocks: blocks)
        guard chain.indices.contains(blocks - 1) else { return nil }
        return chain
    }
}
