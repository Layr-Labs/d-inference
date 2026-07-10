//! Provider-local terminal journal (plan §10.6) — pure in-memory stub for tests.
//!
//! Production Swift journal fsyncs encrypted entries to disk; this crate keeps
//! the ACK/replay/conflict rules testable on Linux.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JournalEntry {
    pub terminal_digest: String,
    pub job_id: String,
    pub attempt_id: String,
    pub lease_id: String,
    pub outcome: String,
    pub prompt_tokens: i32,
    pub completion_tokens: i32,
    pub response_hash: String,
    pub se_signature: String,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum JournalError {
    #[error("journal full")]
    Full,
    #[error("conflict: same attempt different digest")]
    Conflict,
}

#[derive(Debug)]
pub struct TerminalJournal {
    capacity: usize,
    /// attempt_id -> entry (unacked)
    pending: HashMap<String, JournalEntry>,
    /// digest -> disposition after ACK
    acked: HashMap<String, String>,
}

impl TerminalJournal {
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity,
            pending: HashMap::new(),
            acked: HashMap::new(),
        }
    }

    pub fn append(&mut self, entry: JournalEntry) -> Result<(), JournalError> {
        if let Some(prev) = self.pending.get(&entry.attempt_id) {
            if prev.terminal_digest != entry.terminal_digest {
                return Err(JournalError::Conflict);
            }
            return Ok(()); // idempotent same digest
        }
        if let Some(disp) = self.acked.get(&entry.terminal_digest) {
            // Already ACKed — replay returns prior disposition via peek.
            let _ = disp;
            return Ok(());
        }
        if self.pending.len() >= self.capacity {
            return Err(JournalError::Full);
        }
        self.pending.insert(entry.attempt_id.clone(), entry);
        Ok(())
    }

    pub fn ack(&mut self, attempt_id: &str, terminal_digest: &str, disposition: &str) -> bool {
        if let Some(entry) = self.pending.remove(attempt_id) {
            if entry.terminal_digest == terminal_digest {
                self.acked
                    .insert(terminal_digest.to_string(), disposition.to_string());
                return true;
            }
            // Put back on digest mismatch.
            self.pending.insert(attempt_id.to_string(), entry);
            return false;
        }
        self.acked.get(terminal_digest).is_some()
    }

    pub fn unacked(&self) -> Vec<&JournalEntry> {
        self.pending.values().collect()
    }

    pub fn is_full(&self) -> bool {
        self.pending.len() >= self.capacity
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(attempt: &str, digest: &str) -> JournalEntry {
        JournalEntry {
            terminal_digest: digest.into(),
            job_id: "j".into(),
            attempt_id: attempt.into(),
            lease_id: "l".into(),
            outcome: "completed".into(),
            prompt_tokens: 1,
            completion_tokens: 1,
            response_hash: "rh".into(),
            se_signature: "sig".into(),
        }
    }

    #[test]
    fn conflict_on_digest_mismatch() {
        let mut j = TerminalJournal::new(10);
        j.append(entry("a1", "d1")).unwrap();
        assert_eq!(j.append(entry("a1", "d2")).unwrap_err(), JournalError::Conflict);
    }

    #[test]
    fn ack_clears_pending_and_replay_is_ok() {
        let mut j = TerminalJournal::new(10);
        j.append(entry("a1", "d1")).unwrap();
        assert!(j.ack("a1", "d1", "settled"));
        assert!(j.unacked().is_empty());
        assert!(j.append(entry("a1", "d1")).is_ok());
        assert!(j.ack("a1", "d1", "settled"));
    }

    #[test]
    fn full_journal_rejects() {
        let mut j = TerminalJournal::new(1);
        j.append(entry("a1", "d1")).unwrap();
        assert_eq!(j.append(entry("a2", "d2")).unwrap_err(), JournalError::Full);
    }
}
