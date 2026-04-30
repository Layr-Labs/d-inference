//! Disk-backed overflow queue for telemetry events.
//!
//! Format: JSONL (one JSON-encoded `TelemetryEvent` per line).
//! Location: `~/.darkbloom/telemetry-queue.jsonl`.
//! Size cap: 5 MB. On overflow, the oldest half of the file is discarded.
//!
//! The queue is intentionally simple: open-for-append for writes, read+rewrite
//! for drains. It is NOT a cross-process durable queue — one provider process
//! owns the file. A crash mid-write may lose the last partial line; that's
//! acceptable because telemetry is best-effort.

use crate::telemetry::event::TelemetryEvent;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// Maximum size of the disk queue before rotation kicks in.
const MAX_BYTES: u64 = 5 * 1024 * 1024;

/// Disk-backed JSONL queue. Not safe to share across processes.
pub struct DiskQueue {
    path: PathBuf,
}

impl DiskQueue {
    /// Open (creating if missing) the queue at `path`.
    pub fn open(path: impl AsRef<Path>) -> std::io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        Ok(Self { path })
    }

    /// Append an event to the queue. Rotates if the file exceeds `MAX_BYTES`.
    pub fn push(&mut self, event: &TelemetryEvent) -> std::io::Result<()> {
        let line = match serde_json::to_string(event) {
            Ok(s) => s,
            Err(_) => return Ok(()), // unencodable — best-effort drop
        };
        self.rotate_if_needed()?;
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(f, "{}", line)?;
        Ok(())
    }

    /// Drain up to `limit` events from the head of the queue and rewrite the
    /// rest back to disk. Returns the drained events.
    pub fn drain(&mut self, limit: usize) -> Vec<TelemetryEvent> {
        if !self.path.exists() {
            return Vec::new();
        }
        let f = match File::open(&self.path) {
            Ok(f) => f,
            Err(_) => return Vec::new(),
        };
        let reader = BufReader::new(f);
        let mut drained: Vec<TelemetryEvent> = Vec::with_capacity(limit);
        let mut remaining: Vec<String> = Vec::new();
        for line in reader.lines().map_while(Result::ok) {
            if drained.len() < limit {
                if let Ok(ev) = serde_json::from_str::<TelemetryEvent>(&line) {
                    drained.push(ev);
                    continue;
                }
                // Malformed line: drop silently.
                continue;
            }
            remaining.push(line);
        }

        // Rewrite the remaining lines atomically.
        let tmp_path = self.path.with_extension("jsonl.tmp");
        if let Ok(mut tmp) = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp_path)
        {
            for line in &remaining {
                let _ = writeln!(tmp, "{}", line);
            }
            let _ = tmp.flush();
            let _ = std::fs::rename(&tmp_path, &self.path);
        }

        drained
    }

    /// Trim the queue to its most recent half when it grows past `MAX_BYTES`.
    fn rotate_if_needed(&mut self) -> std::io::Result<()> {
        let size = match std::fs::metadata(&self.path) {
            Ok(m) => m.len(),
            Err(_) => return Ok(()),
        };
        if size <= MAX_BYTES {
            return Ok(());
        }

        // Keep the last half: seek to the midpoint, skip the partial first
        // line, copy the rest to a new file.
        let mut f = File::open(&self.path)?;
        let midpoint = size / 2;
        f.seek(SeekFrom::Start(midpoint))?;
        let mut reader = BufReader::new(f);

        // Discard one line that may be partial.
        let mut discard = String::new();
        let _ = reader.read_line(&mut discard);

        let tmp_path = self.path.with_extension("jsonl.tmp");
        let mut tmp = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&tmp_path)?;

        for line in reader.lines().map_while(Result::ok) {
            writeln!(tmp, "{}", line)?;
        }
        tmp.flush()?;
        std::fs::rename(&tmp_path, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::event::{Kind, Severity, Source, TelemetryEvent};

    fn ev(msg: &str) -> TelemetryEvent {
        TelemetryEvent::new(Source::Provider, Severity::Warn, Kind::Log, msg)
    }

    #[test]
    fn push_and_drain_round_trip() {
        let dir = tempdir();
        let path = dir.join("q.jsonl");
        let mut q = DiskQueue::open(&path).unwrap();
        q.push(&ev("a")).unwrap();
        q.push(&ev("b")).unwrap();
        q.push(&ev("c")).unwrap();

        let drained = q.drain(2);
        assert_eq!(drained.len(), 2);
        assert_eq!(drained[0].message, "a");
        assert_eq!(drained[1].message, "b");

        let remaining = q.drain(10);
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].message, "c");
    }

    #[test]
    fn drain_on_empty() {
        let dir = tempdir();
        let path = dir.join("q.jsonl");
        let mut q = DiskQueue::open(&path).unwrap();
        assert!(q.drain(10).is_empty());
    }

    /// Create a unique temp dir for the test, returning its path. Auto-cleaned
    /// by the OS eventually — tests are short-lived.
    fn tempdir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "darkbloom-tel-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
