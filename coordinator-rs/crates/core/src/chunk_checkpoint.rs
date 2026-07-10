//! Billable-output linearization via last-accepted chunk checkpoint (plan §10.6).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChunkCheckpoint {
    pub last_sequence: u64,
    pub completion_tokens: u64,
    pub rolling_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChunkAccept {
    Accepted(ChunkCheckpoint),
    /// Duplicate or older sequence — ignore for billing.
    Stale,
    /// Hash regression / conflict — do not increase charge.
    Conflict,
}

impl ChunkCheckpoint {
    pub fn accept(
        &self,
        sequence: u64,
        completion_tokens: u64,
        rolling_hash: String,
    ) -> ChunkAccept {
        if sequence < self.last_sequence {
            return ChunkAccept::Stale;
        }
        if sequence == self.last_sequence {
            if rolling_hash == self.rolling_hash && completion_tokens == self.completion_tokens {
                return ChunkAccept::Stale;
            }
            return ChunkAccept::Conflict;
        }
        // sequence > last
        if completion_tokens < self.completion_tokens {
            return ChunkAccept::Conflict;
        }
        ChunkAccept::Accepted(ChunkCheckpoint {
            last_sequence: sequence,
            completion_tokens,
            rolling_hash,
        })
    }

    /// Settlement may not charge above this cumulative token count.
    pub fn billable_completion_tokens(&self) -> u64 {
        self.completion_tokens
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advances_and_caps_billing() {
        let mut cp = ChunkCheckpoint::default();
        match cp.accept(1, 4, "h1".into()) {
            ChunkAccept::Accepted(next) => cp = next,
            other => panic!("{other:?}"),
        }
        assert_eq!(cp.billable_completion_tokens(), 4);
        assert!(matches!(cp.accept(1, 4, "h1".into()), ChunkAccept::Stale));
        assert!(matches!(
            cp.accept(2, 3, "h2".into()),
            ChunkAccept::Conflict
        ));
        match cp.accept(2, 8, "h2".into()) {
            ChunkAccept::Accepted(next) => assert_eq!(next.completion_tokens, 8),
            other => panic!("{other:?}"),
        }
    }
}
