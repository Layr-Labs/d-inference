//! Drive ChunkCheckpoint from SequencedChunk pipe output (plan §10.6 / §13.6).

use crate::chunk_pipe::{ChunkPipe, SequencedChunk};
use bytes::Bytes;
use darkbloom_core::{ChunkAccept, ChunkCheckpoint};

/// Apply a sequenced pipe chunk into the billing checkpoint.
/// `completion_tokens_cumulative` is the provider-reported cumulative count.
pub fn accept_pipe_chunk(
    checkpoint: &ChunkCheckpoint,
    chunk: &SequencedChunk,
    completion_tokens_cumulative: u64,
    rolling_hash: String,
) -> ChunkAccept {
    let _ = chunk.bytes; // ciphertext / plaintext bytes not used for billing math
    checkpoint.accept(
        chunk.sequence,
        completion_tokens_cumulative,
        rolling_hash,
    )
}

/// Micro-USD charge estimate from accepted completion tokens.
pub fn billable_cap_from_checkpoint(cp: &ChunkCheckpoint) -> i64 {
    billable_cap_micro_usd(cp, 1)
}

/// Billable cap using an explicit µUSD-per-completion-token rate (DECISIONS #49).
pub fn billable_cap_micro_usd(cp: &ChunkCheckpoint, micro_per_token: i64) -> i64 {
    (cp.billable_completion_tokens() as i64).saturating_mul(micro_per_token.max(0))
}

/// Stream billable token count: never trust an inflated provider claim above
/// what the accepted content can justify (DECISIONS #49).
pub fn stream_billable_tokens(provider_tokens: u64, content_len: usize) -> u64 {
    let content_tokens = ((content_len / 4) as u64).max(1);
    content_tokens.min(provider_tokens.max(0))
}

/// Helper used by streaming settle: enqueue mock content through the pipe and
/// advance the checkpoint with the assigned sequence.
pub fn pipe_and_checkpoint(
    pipe: &ChunkPipe,
    checkpoint: &mut ChunkCheckpoint,
    content: &[u8],
    completion_tokens: u64,
    rolling_hash: &str,
) -> Result<u64, crate::chunk_pipe::PipeError> {
    let seq = pipe.try_send(Bytes::copy_from_slice(content))?;
    match accept_pipe_chunk(
        checkpoint,
        &SequencedChunk {
            sequence: seq,
            bytes: Bytes::copy_from_slice(content),
        },
        completion_tokens,
        rolling_hash.to_string(),
    ) {
        ChunkAccept::Accepted(next) => {
            *checkpoint = next;
            Ok(seq)
        }
        ChunkAccept::Stale | ChunkAccept::Conflict => Ok(seq),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chunk_pipe::bounded_chunk_pipe;

    #[test]
    fn pipe_sequence_advances_checkpoint() {
        let (pipe, _r) = bounded_chunk_pipe(8, 1024);
        let mut cp = ChunkCheckpoint::default();
        let seq = pipe_and_checkpoint(&pipe, &mut cp, b"hello", 4, "h1").unwrap();
        assert_eq!(seq, 1);
        assert_eq!(cp.last_sequence, 1);
        assert_eq!(cp.completion_tokens, 4);
        assert_eq!(billable_cap_from_checkpoint(&cp), 4);
        let seq2 = pipe_and_checkpoint(&pipe, &mut cp, b" world", 8, "h2").unwrap();
        assert_eq!(seq2, 2);
        assert_eq!(cp.completion_tokens, 8);
    }

    #[test]
    fn billable_cap_scales_with_rate() {
        let (pipe, _r) = bounded_chunk_pipe(8, 1024);
        let mut cp = ChunkCheckpoint::default();
        pipe_and_checkpoint(&pipe, &mut cp, b"hi", 5, "h").unwrap();
        assert_eq!(billable_cap_from_checkpoint(&cp), 5);
        assert_eq!(billable_cap_micro_usd(&cp, 10), 50);
    }

    #[test]
    fn stream_billable_tokens_clamps_inflated_provider_claim() {
        assert_eq!(stream_billable_tokens(500, 40), 10); // 40/4 = 10
        assert_eq!(stream_billable_tokens(3, 40), 3); // provider lower wins
        assert_eq!(stream_billable_tokens(0, 0), 0); // empty + zero claim
        assert_eq!(stream_billable_tokens(100, 0), 1); // empty content → 1 token floor
    }
}
