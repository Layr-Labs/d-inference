//! Deadline discipline tests for the request task (plan §9.2.5, §16): the
//! absolute first-content deadline is shared across alternates and never
//! resets; the total request deadline fires; the stream idle timeout closes
//! a silent funded attempt. Driven against `request_task::run` directly
//! with real timers (the pinned workspace tokio lacks `test-util`) and generous assertion margins.
//!
//! These tests race real sub-second timers against the wall clock (two
//! assert explicit elapsed windows), so each takes the suite-wide
//! `crate::support::timing_lock()` to keep concurrent load from
//! stretching the measured windows.

use std::time::Duration;

use bytes::Bytes;
use tokio::sync::mpsc;
use uuid::Uuid;

use darkbloom_core::ids::{ApiKeyId, JobId, LeaseId};
use darkbloom_core::request::RequestOutcome;
use darkbloom_protocol::json_v2::{
    self, ExecutionFacts, FrameV2, PrepareFrame, PreparedFrame, RequestScope, ResourceFacts,
};
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, ControlFrame, DataFrame, ProtocolGen};
use darkbloom_server::request_task::{self, ConsumerEvent, NormalizedRequest};

use crate::support::http::*;

fn normalized(h: &Harness, consumer: mpsc::Sender<ConsumerEvent>) -> NormalizedRequest {
    NormalizedRequest {
        job: JobId::new(Uuid::new_v4()),
        account: h.account,
        api_key: ApiKeyId::new("key-test"),
        spend_cap: None,
        public_model: PUBLIC_MODEL.to_owned(),
        concrete_model: CONCRETE_MODEL.to_owned(),
        body: Bytes::from_static(
            br#"{"model":"gemma-4-26b-4bit","messages":[{"role":"user","content":"hi"}],"stream":true,"max_tokens":64}"#,
        ),
        stream: true,
        estimated_prompt_tokens: 6,
        requested_max_tokens: 64,
        needs_vision: false,
        needs_tools: false,
        paid: true,
        consumer,
    }
}

fn expect_v2_prepare(frame: DataFrame) -> PrepareFrame {
    match frame {
        DataFrame::V2Prepare { frame, .. } => match *frame {
            FrameV2::Prepare(prepare) => prepare,
            other => panic!("expected prepare, got {}", other.type_str()),
        },
        other => panic!("expected v2 prepare, got {other:?}"),
    }
}

fn scope_with_lease(prepare: &PrepareFrame, lease: LeaseId) -> RequestScope {
    RequestScope {
        lease_id: Some(json_v2::LeaseId(*lease.as_bytes())),
        ..prepare.scope
    }
}

fn prepared_event(prepare: &PrepareFrame, lease: LeaseId) -> AttemptEvent {
    AttemptEvent::Prepared {
        lease,
        ttl: Duration::from_secs(30),
        billable_prompt_tokens: 6,
        queue_depth: 0,
        prefill_can_start: true,
        frame: Box::new(PreparedFrame {
            scope: scope_with_lease(prepare, lease),
            ttl_ms: 30_000,
            billable_input_tokens: 6,
            resource: ResourceFacts::default(),
            execution: ExecutionFacts {
                engine_queue_depth: 0,
                prefill_can_start: true,
                predicted_first_content_ms: Some(20),
            },
        }),
    }
}

/// The first-content deadline is absolute and shared: a sequential
/// alternate does NOT get a fresh window. Primary rejects at t=150ms; the
/// silent alternate is cut at the ORIGINAL t=400ms deadline (plus the
/// bounded cancel-evidence wait), never at 150ms + 400ms.
#[tokio::test]
async fn first_content_deadline_is_shared_across_alternates() {
    let _timing = crate::support::timing_lock().await;
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V2, ProtocolGen::V2])
        .admit_script(vec![AdmitReply::Grant(0), AdmitReply::Grant(1)])
        .policy(|p| {
            p.first_content_base = Duration::from_millis(400);
            p.first_content_per_prompt_token = Duration::ZERO;
            p.terminal_wait = Duration::from_millis(100);
            p.hedge_enabled = false;
        })
        .build();
    let mut provider_b = h.providers.remove(1);
    let mut provider_a = h.providers.remove(0);

    let script = tokio::spawn(async move {
        let attach_a = provider_a.expect_attach().await;
        let prepare_a = expect_v2_prepare(provider_a.expect_data().await);
        tokio::time::sleep(Duration::from_millis(150)).await;
        // Capacity-class rejection triggers the sequential alternate.
        let mut rejection = darkbloom_protocol::json_v2::TerminalFrame {
            scope: scope_with_lease(&prepare_a, LeaseId::new(Uuid::new_v4())),
            provider_id: "prov-a".to_owned(),
            model_id: CONCRETE_MODEL.to_owned(),
            origin_session_epoch: json_v2::SessionEpoch(1),
            outcome: json_v2::TerminalOutcome::Failed,
            error_class: Some(json_v2::ErrorClass::Capacity),
            usage: json_v2::TerminalUsage::default(),
            generated_tokens: 0,
            response_hash: json_v2::ResponseHash([0; 32]),
            checkpoint: json_v2::RollingHashCheckpoint::default(),
            se_signature: String::new(),
        };
        rejection.checkpoint.rolling_hash = json_v2::ResponseHash([0; 32]);
        attach_a
            .events
            .send(AttemptEvent::Terminal(Box::new(rejection)))
            .await
            .expect("rejection");

        // The alternate lands on B, which never responds.
        let _attach_b = provider_b.expect_attach().await;
        let _prepare_b = expect_v2_prepare(provider_b.expect_data().await);
        // Keep the sinks alive so the attempt cannot close via session loss.
        tokio::time::sleep(Duration::from_secs(10)).await;
        drop(_attach_b);
    });

    let (tx, _rx) = mpsc::channel(64);
    let request = normalized(&h, tx);
    let started = tokio::time::Instant::now();
    let report = request_task::run(h.task_deps.clone(), request).await;
    let elapsed = started.elapsed();

    assert_eq!(report.outcome, RequestOutcome::DeadlineExceeded);
    assert!(!report.committed);
    // Original 400ms deadline + bounded 100ms evidence wait ≈ 500ms. A
    // deadline reset at the alternate would finish no earlier than
    // 150 + 400 + 100 = 650ms, so any result under 600ms proves sharing.
    assert!(
        elapsed >= Duration::from_millis(400) && elapsed < Duration::from_millis(600),
        "deadline must not reset for the alternate; elapsed {elapsed:?}"
    );
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "release"]);
    script.abort();
}

/// The absolute total request deadline fires mid-stream: cancel goes to the
/// provider, and with no terminal inside the bounded wait the job escalates
/// to review (money held for reconciliation, never guessed).
#[tokio::test]
async fn total_deadline_fires_post_content() {
    let _timing = crate::support::timing_lock().await;
    let mut h = HarnessBuilder::new()
        .policy(|p| {
            p.request_deadline = Duration::from_millis(500);
            p.terminal_wait = Duration::from_millis(100);
            p.hedge_enabled = false;
        })
        .build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let prepare = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease))
            .await
            .expect("prepared");
        match provider.expect_control().await {
            ControlFrame::V2(f) => assert!(matches!(*f, FrameV2::Start(_))),
            other => panic!("expected start, got {other:?}"),
        }
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("tick").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");
        // Silence. The total deadline must cancel us.
        match provider.expect_control().await {
            ControlFrame::V2(f) => assert!(matches!(*f, FrameV2::Cancel(_))),
            other => panic!("expected cancel, got {other:?}"),
        }
        // Never send a terminal: the bounded wait must elapse.
    });

    let (tx, mut rx) = mpsc::channel(64);
    let request = normalized(&h, tx);
    let started = tokio::time::Instant::now();
    let report = request_task::run(h.task_deps.clone(), request).await;
    let elapsed = started.elapsed();

    assert_eq!(report.outcome, RequestOutcome::DeadlineExceeded);
    assert!(report.committed);
    assert!(
        elapsed >= Duration::from_millis(500) && elapsed <= Duration::from_millis(900),
        "total deadline plus bounded terminal wait; elapsed {elapsed:?}"
    );
    // Money is escalated, not released: content was exposed (plan §13.5).
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "resize", "mark_running", "review"]);

    // The consumer saw the committed chunk, then the timeout error event.
    let first = rx.recv().await.expect("chunk event");
    assert!(matches!(first, ConsumerEvent::Chunk(_)));
    let second = rx.recv().await.expect("failure event");
    match second {
        ConsumerEvent::Failed { error_type, .. } => assert_eq!(error_type, "timeout"),
        other => panic!("expected Failed, got {other:?}"),
    }
    script.await.expect("script");
}

/// A funded attempt that goes silent mid-stream is closed by the idle
/// timeout: provider-lost outcome, review escalation (content exposed).
#[tokio::test]
async fn stream_idle_timeout_closes_silent_attempt() {
    let _timing = crate::support::timing_lock().await;
    let mut h = HarnessBuilder::new()
        .policy(|p| {
            p.stream_idle_timeout = Duration::from_millis(200);
            p.hedge_enabled = false;
        })
        .build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let prepare = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease))
            .await
            .expect("prepared");
        match provider.expect_control().await {
            ControlFrame::V2(f) => assert!(matches!(*f, FrameV2::Start(_))),
            other => panic!("expected start, got {other:?}"),
        }
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("only").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");
        // Then silence forever: keep the sinks alive.
        tokio::time::sleep(Duration::from_secs(30)).await;
        drop(attach);
    });

    let (tx, mut rx) = mpsc::channel(64);
    let request = normalized(&h, tx);
    let report = request_task::run(h.task_deps.clone(), request).await;

    assert_eq!(report.outcome, RequestOutcome::ProviderLost);
    assert!(report.committed);
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "resize", "mark_running", "review"]);

    let first = rx.recv().await.expect("chunk event");
    assert!(matches!(first, ConsumerEvent::Chunk(_)));
    let second = rx.recv().await.expect("failure event");
    match second {
        ConsumerEvent::Failed { error_type, .. } => assert_eq!(error_type, "provider_error"),
        other => panic!("expected Failed, got {other:?}"),
    }
    script.abort();
}
