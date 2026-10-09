use super::{Mode, PreloadOperation, Readiness, ReadinessGate};
use crate::metrics::Metrics;
use crate::preload::{PreloadError, PreloadReport, PreloadResult, PreloadStatus};
use std::collections::HashSet;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;

fn report(results: &[(&str, PreloadStatus)]) -> PreloadReport {
    PreloadReport::from_results(
        results
            .iter()
            .map(|(id, status)| PreloadResult {
                prompt_contract_id: (*id).into(),
                status: *status,
            })
            .collect(),
    )
}

fn counters(metrics: &Metrics) -> (u64, u64) {
    let observed = metrics.snapshot().preloads;
    (observed.runs, observed.failed)
}

#[test]
fn dropped_operation_closes_membership_and_counts_failure_once() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let a = "a".repeat(64);
    assert!(
        gate.allows(&a),
        "only the initial library compatibility state is lazy"
    );
    gate.mark_starting();
    assert!(!gate.allows(&a));
    let operation = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    assert_eq!(counters(&metrics), (1, 0));
    drop(operation);
    assert_eq!(gate.status(), Readiness::Degraded);
    assert!(!gate.allows(&a));
    assert_eq!(counters(&metrics), (1, 1));
    // Readbacks cannot reclassify the dropped operation or restore LegacyLazy.
    assert_eq!(gate.status(), Readiness::Degraded);
    assert_eq!(counters(&metrics), (1, 1));

    let recovered = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    recovered.finish(&report(&[(&a, PreloadStatus::Cold)]));
    assert!(gate.allows(&a));
    assert!(!gate.allows(&"b".repeat(64)));
    assert_eq!(
        counters(&metrics),
        (2, 1),
        "successful finish was followed by a failed Drop"
    );
}

#[test]
fn partial_membership_and_all_failed_state_keep_batch_failure_accounting() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let (a, b) = ("a".repeat(64), "b".repeat(64));
    let partial = report(&[(&a, PreloadStatus::Cold), (&b, PreloadStatus::Failed)]);
    assert!(!partial.ready);
    assert_eq!(partial.status, "degraded");
    PreloadOperation::begin(gate.clone(), metrics.clone(), 2)
        .unwrap()
        .finish(&partial);
    assert_eq!(gate.status(), Readiness::Ready);
    assert!(gate.allows(&a));
    assert!(!gate.allows(&b));
    assert_eq!(
        counters(&metrics),
        (1, 1),
        "one partial batch must count one failure, not zero/two"
    );

    let failed = report(&[(&a, PreloadStatus::Failed), (&b, PreloadStatus::Failed)]);
    PreloadOperation::begin(gate.clone(), metrics.clone(), 2)
        .unwrap()
        .finish(&failed);
    assert_eq!(gate.status(), Readiness::Degraded);
    assert!(!gate.allows(&a) && !gate.allows(&b));
    assert_eq!(counters(&metrics), (2, 2));
}

#[test]
fn late_old_operation_drop_cannot_close_a_newer_published_set() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let (a, c) = ("a".repeat(64), "c".repeat(64));
    let old = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    gate.mark_starting(); // Explicitly supersede the old operation.
    let current = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    current.finish(&report(&[(&c, PreloadStatus::Warm)]));
    drop(old);
    assert_eq!(gate.status(), Readiness::Ready);
    assert!(gate.allows(&c) && !gate.allows(&a));
    assert_eq!(counters(&metrics), (2, 1));
}

#[test]
fn late_old_operation_finish_cannot_replace_a_newer_published_set() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let (a, c) = ("a".repeat(64), "c".repeat(64));
    let old = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    gate.mark_starting();
    PreloadOperation::begin(gate.clone(), metrics.clone(), 1)
        .unwrap()
        .finish(&report(&[(&c, PreloadStatus::Cold)]));
    old.finish(&report(&[(&a, PreloadStatus::Cold)]));
    assert_eq!(gate.status(), Readiness::Ready);
    assert!(gate.allows(&c) && !gate.allows(&a));
    // This is a stale publication check, not an invented failed-load outcome.
    assert_eq!(counters(&metrics), (2, 0));
}

#[test]
fn poisoned_readiness_mutex_never_reopens_membership_or_lazy_mode() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let a = "a".repeat(64);
    let operation = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    let poisoned = catch_unwind(AssertUnwindSafe(|| {
        let _state = gate.0.lock().unwrap();
        panic!("injected readiness-state poison");
    }));
    assert!(poisoned.is_err() && gate.0.is_poisoned());
    assert_eq!(gate.status(), Readiness::Degraded);
    assert!(!gate.allows(&a));
    operation.finish(&report(&[(&a, PreloadStatus::Cold)]));
    assert_eq!(gate.status(), Readiness::Degraded);
    assert!(!gate.allows(&a));
    gate.mark_starting();
    assert_eq!(gate.status(), Readiness::Degraded);
    let attempted = PreloadOperation::begin(gate.clone(), metrics, 1).unwrap();
    attempted.finish(&report(&[(&a, PreloadStatus::Warm)]));
    assert_eq!(gate.status(), Readiness::Degraded);
    assert!(!gate.allows(&a));
}

#[test]
fn generation_exhaustion_rejects_new_work_and_old_publication_without_wrapping() {
    let gate = Arc::new(ReadinessGate::new());
    let metrics = Arc::new(Metrics::default());
    let a = "a".repeat(64);
    {
        let mut state = gate.0.lock().unwrap();
        state.operation = u64::MAX - 1;
        state.mode = Mode::Usable(HashSet::from([a.clone()]));
    }
    let last = PreloadOperation::begin(gate.clone(), metrics.clone(), 1).unwrap();
    assert_eq!(last.operation, u64::MAX);
    gate.mark_starting(); // Cannot increment; this must close, not wrap to zero.
    assert_eq!(gate.status(), Readiness::Degraded);
    last.finish(&report(&[(&a, PreloadStatus::Cold)]));
    assert!(!gate.allows(&a));
    assert!(matches!(
        PreloadOperation::begin(gate.clone(), metrics.clone(), 1),
        Err(PreloadError::Worker)
    ));
    assert_eq!(gate.0.lock().unwrap().operation, u64::MAX);
    assert_eq!(gate.status(), Readiness::Degraded);
    assert_eq!(
        counters(&metrics),
        (2, 1),
        "exhausted begin must classify failure exactly once"
    );
}
