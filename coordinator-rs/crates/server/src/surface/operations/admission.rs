use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};

/// Linearizable admission gate used by HTTP handlers and external workers.
///
/// Admission is check-increment-recheck: a drain that races an entrant either
/// rejects it on the second check or observes it in the active counter.
#[derive(Clone, Debug, Default)]
pub struct AdmissionGate {
    inner: Arc<AdmissionState>,
}

#[derive(Debug, Default)]
struct AdmissionState {
    draining: AtomicBool,
    handoff: AtomicBool,
    external_fenced: AtomicBool,
    active_inference: AtomicU64,
    active_mutations: AtomicU64,
    active_external: AtomicU64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionKind {
    Inference,
    Mutation,
    External,
}

#[derive(Debug)]
pub struct AdmissionGuard {
    gate: AdmissionGate,
    kind: AdmissionKind,
}

impl AdmissionGate {
    #[must_use]
    pub fn is_draining(&self) -> bool {
        self.inner.draining.load(Ordering::SeqCst)
    }

    pub fn set_draining(&self, draining: bool) {
        if !draining && self.inner.handoff.load(Ordering::SeqCst) {
            return;
        }
        self.inner.draining.store(draining, Ordering::SeqCst);
        if !draining {
            self.inner.external_fenced.store(false, Ordering::SeqCst);
        }
    }

    pub fn begin_handoff(&self) {
        self.inner.handoff.store(true, Ordering::SeqCst);
        self.inner.draining.store(true, Ordering::SeqCst);
    }

    #[must_use]
    pub fn external_fenced(&self) -> bool {
        self.inner.external_fenced.load(Ordering::SeqCst)
    }

    pub fn fence_external(&self) {
        self.inner.external_fenced.store(true, Ordering::SeqCst);
    }

    pub fn enter(&self, kind: AdmissionKind) -> Result<AdmissionGuard, AdmissionRejected> {
        if self.rejects(kind) {
            return Err(AdmissionRejected);
        }
        self.counter(kind).fetch_add(1, Ordering::SeqCst);
        if self.rejects(kind) {
            self.counter(kind).fetch_sub(1, Ordering::SeqCst);
            return Err(AdmissionRejected);
        }
        Ok(AdmissionGuard {
            gate: self.clone(),
            kind,
        })
    }

    #[must_use]
    pub fn active_inference(&self) -> u64 {
        self.inner.active_inference.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn active_mutations(&self) -> u64 {
        self.inner.active_mutations.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn active_external(&self) -> u64 {
        self.inner.active_external.load(Ordering::SeqCst)
    }

    fn rejects(&self, kind: AdmissionKind) -> bool {
        match kind {
            AdmissionKind::Inference | AdmissionKind::Mutation => self.is_draining(),
            AdmissionKind::External => self.external_fenced(),
        }
    }

    fn counter(&self, kind: AdmissionKind) -> &AtomicU64 {
        match kind {
            AdmissionKind::Inference => &self.inner.active_inference,
            AdmissionKind::Mutation => &self.inner.active_mutations,
            AdmissionKind::External => &self.inner.active_external,
        }
    }
}

impl Drop for AdmissionGuard {
    fn drop(&mut self) {
        let previous = self.gate.counter(self.kind).fetch_sub(1, Ordering::SeqCst);
        debug_assert!(previous > 0, "admission counter underflow");
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
#[error("coordinator is draining")]
pub struct AdmissionRejected;

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier, mpsc};

    use super::{AdmissionGate, AdmissionKind};

    #[test]
    fn drain_rejects_new_work_and_counts_existing_work_by_class() {
        let gate = AdmissionGate::default();
        let inference = gate.enter(AdmissionKind::Inference).expect("inference");
        let mutation = gate.enter(AdmissionKind::Mutation).expect("mutation");
        assert_eq!(gate.active_inference(), 1);
        assert_eq!(gate.active_mutations(), 1);

        gate.set_draining(true);
        assert!(gate.enter(AdmissionKind::Inference).is_err());
        assert!(gate.enter(AdmissionKind::Mutation).is_err());
        assert!(
            gate.enter(AdmissionKind::External).is_ok(),
            "durable recovery continues until the external fence is closed"
        );
        gate.fence_external();
        assert!(gate.enter(AdmissionKind::External).is_err());
        drop(inference);
        drop(mutation);
        assert_eq!(gate.active_inference(), 0);
        assert_eq!(gate.active_mutations(), 0);
    }

    #[test]
    fn racing_drain_cannot_report_quiescent_while_an_entry_mutates() {
        for _ in 0..2_000 {
            let gate = AdmissionGate::default();
            let start = Arc::new(Barrier::new(2));
            let (outcome_sender, outcome_receiver) = mpsc::sync_channel(0);
            let (release_sender, release_receiver) = mpsc::sync_channel(0);
            let worker_gate = gate.clone();
            let worker_start = start.clone();
            let worker = std::thread::spawn(move || {
                worker_start.wait();
                match worker_gate.enter(AdmissionKind::Mutation) {
                    Ok(guard) => {
                        outcome_sender.send(true).expect("report accepted entry");
                        release_receiver.recv().expect("release accepted entry");
                        drop(guard);
                    }
                    Err(_) => outcome_sender.send(false).expect("report rejected entry"),
                }
            });
            start.wait();
            gate.set_draining(true);
            let accepted = outcome_receiver.recv().expect("entry outcome");
            if accepted {
                assert_eq!(
                    gate.active_mutations(),
                    1,
                    "an accepted mutation must remain visible until its guard exits"
                );
                release_sender.send(()).expect("release worker");
            } else {
                assert_eq!(gate.active_mutations(), 0);
            }
            worker.join().expect("worker");
            assert_eq!(gate.active_mutations(), 0);
        }
    }

    #[test]
    fn handoff_drain_is_irreversible() {
        let gate = AdmissionGate::default();
        gate.begin_handoff();
        gate.set_draining(false);
        assert!(gate.is_draining());
        assert!(gate.enter(AdmissionKind::Mutation).is_err());
    }
}
