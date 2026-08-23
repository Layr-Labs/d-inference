use sha2::{Digest, Sha256};
use thiserror::Error;

pub const BLOCK_HASH_DOMAIN: &[u8] = b"darkbloom.prefix-block-chain.v1";
pub const ZERO_PARENT: [u8; 32] = [0; 32];

#[derive(Debug, Error)]
pub enum BlockHashError {
    #[error("block identity is too large")]
    IdentityTooLarge,
    #[error("block index is too large")]
    BlockIndexTooLarge,
}

pub fn block_hash(
    contract_id: &[u8],
    scope_id: &[u8],
    parent: &[u8; 32],
    block_index: u32,
    token_ids: &[u32],
) -> Result<[u8; 32], BlockHashError> {
    let mut encoded = Vec::with_capacity(
        BLOCK_HASH_DOMAIN.len() + contract_id.len() + scope_id.len() + token_ids.len() * 4 + 44,
    );
    encoded.extend_from_slice(BLOCK_HASH_DOMAIN);
    push_field(&mut encoded, contract_id)?;
    push_field(&mut encoded, scope_id)?;
    encoded.extend_from_slice(parent);
    encoded.extend_from_slice(&block_index.to_be_bytes());
    for token in token_ids {
        encoded.extend_from_slice(&token.to_be_bytes());
    }
    Ok(Sha256::digest(encoded).into())
}

pub fn chain_hashes(
    contract_id: &[u8],
    scope_id: &[u8],
    tokens: &[u32],
    block_size: usize,
) -> Result<Vec<[u8; 32]>, BlockHashError> {
    if block_size == 0 {
        return Ok(Vec::new());
    }
    let mut hashes = Vec::with_capacity(tokens.len() / block_size);
    let mut parent = ZERO_PARENT;
    for (index, block) in tokens.chunks_exact(block_size).enumerate() {
        let block_index = u32::try_from(index).map_err(|_| BlockHashError::BlockIndexTooLarge)?;
        parent = block_hash(contract_id, scope_id, &parent, block_index, block)?;
        hashes.push(parent);
    }
    Ok(hashes)
}

pub fn last_token_hash<'a>(
    tokens: &[u32],
    hashes: &'a [[u8; 32]],
    block_size: usize,
) -> Option<&'a [u8; 32]> {
    if block_size == 0 {
        return None;
    }
    let lookup_blocks = tokens.len().saturating_sub(1) / block_size;
    lookup_blocks
        .checked_sub(1)
        .and_then(|index| hashes.get(index))
}

fn push_field(out: &mut Vec<u8>, value: &[u8]) -> Result<(), BlockHashError> {
    let len = u32::try_from(value.len()).map_err(|_| BlockHashError::IdentityTooLarge)?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn exact_last_token_rule_uses_last_complete_boundary() {
        let contract = b"contract";
        for count in [0, 1, 255, 256, 257, 511, 512] {
            let tokens = (0..count as u32).collect::<Vec<_>>();
            let hashes = chain_hashes(contract, b"", &tokens, 256).unwrap();
            assert_eq!(hashes.len(), count / 256);
            assert_eq!(
                last_token_hash(&tokens, &hashes, 256),
                match count {
                    0..=256 => None,
                    257..=512 => hashes.first(),
                    _ => unreachable!(),
                }
            );
        }
    }

    proptest! {
        #[test]
        fn changing_any_identity_or_token_changes_hash(
            contract in proptest::collection::vec(any::<u8>(), 1..64),
            scope in proptest::collection::vec(any::<u8>(), 0..64),
            tokens in proptest::collection::vec(any::<u32>(), 1..512),
            parent in any::<[u8; 32]>(),
            block_index in any::<u32>(),
        ) {
            let hash = block_hash(&contract, &scope, &parent, block_index, &tokens).unwrap();

            let mut changed_contract = contract.clone();
            changed_contract[0] ^= 1;
            prop_assert_ne!(
                hash,
                block_hash(&changed_contract, &scope, &parent, block_index, &tokens).unwrap()
            );

            let mut changed_scope = scope.clone();
            if changed_scope.is_empty() {
                changed_scope.push(0);
            } else {
                changed_scope[0] ^= 1;
            }
            prop_assert_ne!(
                hash,
                block_hash(&contract, &changed_scope, &parent, block_index, &tokens).unwrap()
            );

            let mut changed_parent = parent;
            changed_parent[0] ^= 1;
            prop_assert_ne!(
                hash,
                block_hash(&contract, &scope, &changed_parent, block_index, &tokens).unwrap()
            );

            prop_assert_ne!(
                hash,
                block_hash(
                    &contract,
                    &scope,
                    &parent,
                    block_index.wrapping_add(1),
                    &tokens,
                )
                .unwrap()
            );

            let mut changed_tokens = tokens.clone();
            changed_tokens[0] ^= 1;
            prop_assert_ne!(
                hash,
                block_hash(&contract, &scope, &parent, block_index, &changed_tokens).unwrap()
            );
        }
    }
}
