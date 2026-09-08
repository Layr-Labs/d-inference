//! v1 provider-session integration tests: a real axum WebSocket server
//! running `provider_session::serve`, a real `FleetActor`, and a fake Swift
//! provider speaking genuine v1 JSON frames over tokio-tungstenite
//! (plan §7.4, §9.1, §15.2).

use std::time::Duration;

use bytes::Bytes;

use darkbloom_core::ids::AttemptId;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_server::contracts::{
    AdmitOutcome, AttemptEvent, ControlFrame, DataFrame, SubmitError,
};

use crate::support::session::{attempt_sinks, outcome_kind, FakeProvider, Harness, ALIAS, MODEL};

fn inference_request_json(request_id: &str) -> Bytes {
    Bytes::from(
        serde_json::json!({
            "type": "inference_request",
            "request_id": request_id,
            "body": {"model": MODEL, "messages": null, "stream": true},
        })
        .to_string(),
    )
}

#[tokio::test]
async fn full_v1_flow_streams_encrypted_chunks() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-FLOW").await;
    provider.establish(false).await;
    provider.send_heartbeat(MODEL, "running").await;

    // Admission: alias resolves, provider granted with a live handle.
    let grant = harness.admit_until_grant(ALIAS).await;
    assert_eq!(grant.concrete_model.as_str(), MODEL);

    // Attach the attempt, dispatch the request on the data lane, and wait
    // for the on-wire completion (WriteText-blocks-to-wire semantics).
    let (sinks, mut events, mut chunks) = attempt_sinks();
    let request_id = "req-1";
    grant
        .session
        .attach_attempt(
            request_id.to_owned(),
            AttemptId::new(uuid::Uuid::new_v4()),
            sinks,
        )
        .await
        .expect("attach");
    let on_wire = grant
        .session
        .submit_data(DataFrame::V1InferenceRequest(inference_request_json(
            request_id,
        )))
        .expect("submit");
    on_wire.await.expect("writer alive").expect("frame on wire");

    // The provider sees the request and accepts.
    let request = provider.next_json().await;
    assert_eq!(request["type"], "inference_request");
    assert_eq!(request["request_id"], request_id);
    provider
        .send_json(&serde_json::json!({
            "type": "inference_accepted",
            "request_id": request_id,
        }))
        .await;
    match tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .expect("event in time")
        .expect("events open")
    {
        AttemptEvent::AcceptedV1 => {}
        other => panic!("expected AcceptedV1, got {other:?}"),
    }

    // Encrypted chunks: the provider seals to the per-request session key
    // with its REGISTERED X25519 key; the session validates the sender key
    // and forwards the RAW `nonce || box` ciphertext bytes — exactly what
    // the request task's precomputed shared key opens
    // (`AttemptCrypto::open_chunk`); this test plays that role.
    let (session_pub, session_secret) = nacl_box::generate_keypair();
    let plaintexts = [
        r#"{"choices":[{"delta":{"content":"Hel"}}]}"#,
        r#"{"choices":[{"delta":{"content":"lo"}}]}"#,
    ];
    for plaintext in plaintexts {
        let sealed = nacl_box::seal(plaintext.as_bytes(), &session_pub, &provider.x25519_secret)
            .expect("seal chunk");
        provider
            .send_json(&serde_json::json!({
                "type": "inference_response_chunk",
                "request_id": request_id,
                "encrypted_data": {
                    "ephemeral_public_key": sealed.ephemeral_public_key,
                    "ciphertext": sealed.ciphertext,
                },
            }))
            .await;
    }
    let provider_pub = nacl_box::parse_public_key(&provider.x25519_pub_b64).expect("provider key");
    let shared = nacl_box::precompute_shared_key(&provider_pub, &session_secret);
    for expected in plaintexts {
        let frame = tokio::time::timeout(Duration::from_secs(5), chunks.recv())
            .await
            .expect("chunk in time")
            .expect("pipe open");
        assert_eq!(frame.sequence, 0, "v1 chunks carry sequence 0");
        let opened =
            nacl_box::open_bytes_with_shared_key(&frame.payload, &shared).expect("decrypt");
        assert_eq!(opened, expected.as_bytes());
    }

    // Terminal: usage flows through CompleteV1.
    provider
        .send_json(&serde_json::json!({
            "type": "inference_complete",
            "request_id": request_id,
            "usage": {"prompt_tokens": 12, "completion_tokens": 2},
            "response_hash": "abc123",
        }))
        .await;
    match tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .expect("event in time")
        .expect("events open")
    {
        AttemptEvent::CompleteV1 {
            usage,
            response_hash,
            ..
        } => {
            let usage = usage.expect("usage present");
            assert_eq!(usage.prompt_tokens, 12);
            assert_eq!(usage.completion_tokens, 2);
            assert_eq!(response_hash.as_deref(), Some("abc123"));
        }
        other => panic!("expected CompleteV1, got {other:?}"),
    }

    // Zombie stream: after detach, a late chunk draws a throttled cancel.
    grant
        .session
        .detach_attempt(request_id.to_owned())
        .await
        .expect("detach");
    let sealed = nacl_box::seal(b"late", &session_pub, &provider.x25519_secret).expect("seal");
    provider
        .send_json(&serde_json::json!({
            "type": "inference_response_chunk",
            "request_id": request_id,
            "encrypted_data": {
                "ephemeral_public_key": sealed.ephemeral_public_key,
                "ciphertext": sealed.ciphertext,
            },
        }))
        .await;
    let cancel = provider.next_json().await;
    assert_eq!(cancel["type"], "cancel");
    assert_eq!(cancel["request_id"], request_id);

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn chunk_sender_key_mismatch_is_rejected_not_forwarded() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-VIOL").await;
    provider.establish(false).await;
    provider.send_heartbeat(MODEL, "idle").await;

    let grant = harness.admit_until_grant(ALIAS).await;
    let (sinks, mut events, mut chunks) = attempt_sinks();
    grant
        .session
        .attach_attempt(
            "req-v".to_owned(),
            AttemptId::new(uuid::Uuid::new_v4()),
            sinks,
        )
        .await
        .expect("attach");

    // Seal with a DIFFERENT key than the registered one: wrong-key chunks
    // are never forwarded (plan §9.1.7) and surface as a 502 to the task.
    let (session_pub, _) = nacl_box::generate_keypair();
    let (_, rogue_secret) = nacl_box::generate_keypair();
    let sealed = nacl_box::seal(b"evil", &session_pub, &rogue_secret).expect("seal");
    provider
        .send_json(&serde_json::json!({
            "type": "inference_response_chunk",
            "request_id": "req-v",
            "encrypted_data": {
                "ephemeral_public_key": sealed.ephemeral_public_key,
                "ciphertext": sealed.ciphertext,
            },
        }))
        .await;

    match tokio::time::timeout(Duration::from_secs(5), events.recv())
        .await
        .expect("event in time")
        .expect("events open")
    {
        AttemptEvent::ErrorV1 { status_code, .. } => assert_eq!(status_code, 502),
        other => panic!("expected ErrorV1, got {other:?}"),
    }
    let nothing = tokio::time::timeout(Duration::from_millis(200), chunks.recv()).await;
    assert!(nothing.is_err(), "violating chunk must not reach the pipe");

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn no_heartbeat_means_model_not_ready_retry() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-COLD").await;
    provider.establish(false).await;
    // Registered + trusted, but NO heartbeat: nothing is warm.
    tokio::time::sleep(Duration::from_millis(200)).await;

    match harness.admit_once(ALIAS).await {
        AdmitOutcome::RetryAfter { .. } => {}
        other => panic!(
            "expected RetryAfter before first heartbeat, got {}",
            outcome_kind(&other)
        ),
    }

    // The heartbeat is exactly what flips it to a grant.
    provider.send_heartbeat(MODEL, "running").await;
    let _ = harness.admit_until_grant(ALIAS).await;

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn reconnect_supersedes_prior_epoch() {
    let harness = Harness::start().await;
    let mut first =
        FakeProvider::connect_keyed(harness.addr, "SER-EPOCH", [0x51; 32], [0x61; 32]).await;
    first.establish(false).await;
    first.send_heartbeat(MODEL, "running").await;

    let old_grant = harness.admit_until_grant(ALIAS).await;
    let old_epoch = old_grant.session.epoch;

    // Same stable identity (same serial + keys) connects again: the fleet
    // mints the next epoch and fences the old session.
    let mut second =
        FakeProvider::connect_keyed(harness.addr, "SER-EPOCH", [0x51; 32], [0x61; 32]).await;
    second.establish(false).await;
    second.send_heartbeat(MODEL, "running").await;

    let new_grant = harness.admit_until_grant(ALIAS).await;
    assert_eq!(
        new_grant.provider, old_grant.provider,
        "same stable identity"
    );
    assert!(new_grant.session.epoch > old_epoch, "epoch must advance");

    // The OLD session's writes fail once the fence lands.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        match old_grant
            .session
            .submit_data(DataFrame::RawJson(Bytes::from_static(
                b"{\"type\":\"noop\"}",
            ))) {
            Err(SubmitError::Closed) => break,
            Err(SubmitError::LaneFull) => panic!("old lane full instead of closed"),
            Ok(on_wire) => {
                // Accepted pre-fence: the write must resolve as failed.
                if let Ok(Err(_)) | Err(_) = on_wire.await {
                    break;
                }
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "old epoch session was never fenced"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    // The NEW session is routable end-to-end: a dispatch reaches provider 2.
    let (sinks, _events, _chunks) = attempt_sinks();
    new_grant
        .session
        .attach_attempt(
            "req-2".to_owned(),
            AttemptId::new(uuid::Uuid::new_v4()),
            sinks,
        )
        .await
        .expect("attach");
    let on_wire = new_grant
        .session
        .submit_data(DataFrame::V1InferenceRequest(inference_request_json(
            "req-2",
        )))
        .expect("submit");
    on_wire.await.expect("writer alive").expect("on wire");
    let request = second.next_json().await;
    assert_eq!(request["request_id"], "req-2");

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn silent_socket_is_reaped_by_liveness_timeout() {
    let config = darkbloom_server::provider_session::SessionConfig {
        read_timeout: Duration::from_millis(300),
        ..Default::default()
    };
    let harness =
        Harness::start_with(config, darkbloom_server::fleet::FleetTunables::default()).await;

    let mut provider = FakeProvider::connect(&harness, "SER-SILENT").await;
    provider.establish(false).await;
    provider.send_heartbeat(MODEL, "running").await;
    let _ = harness.admit_until_grant(ALIAS).await;

    // The provider goes silent: no heartbeats, no frames. The session's
    // read-liveness deadline (~Go's 90s eviction sweep) must reap it and
    // close the socket.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        use futures::StreamExt;
        match tokio::time::timeout_at(deadline, provider.ws.next()).await {
            Ok(None) => break,
            Ok(Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_)))) => break,
            Ok(Some(Ok(_))) => continue,
            Ok(Some(Err(_))) => break,
            Err(_) => panic!("silent session was never reaped"),
        }
    }

    // Post-teardown the provider is no longer routable.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while let AdmitOutcome::Grant(_) = harness.admit_once(ALIAS).await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "dead session stayed routable"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn control_frames_overtake_queued_data_frames() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-PRIO").await;
    provider.establish(false).await;
    provider.send_heartbeat(MODEL, "running").await;
    let grant = harness.admit_until_grant(ALIAS).await;

    // A ~24 MiB data frame saturates the socket while the fake provider is
    // not reading, pinning the writer inside the send; everything submitted
    // meanwhile queues in the lanes.
    let big = {
        let mut json = String::with_capacity(24 * 1024 * 1024 + 64);
        json.push_str(r#"{"type":"noop","pad":""#);
        json.push_str(&"a".repeat(24 * 1024 * 1024));
        json.push_str("\"}");
        Bytes::from(json)
    };
    let big_wire = grant
        .session
        .submit_data(DataFrame::RawJson(big))
        .expect("submit big frame");
    // Let the writer dequeue the big frame and block on the socket.
    tokio::time::sleep(Duration::from_millis(150)).await;

    let d2_wire = grant
        .session
        .submit_data(DataFrame::RawJson(Bytes::from_static(
            br#"{"type":"noop","marker":"d2"}"#,
        )))
        .expect("submit d2");
    let cancel_wire = grant
        .session
        .submit_control(ControlFrame::V1Cancel {
            request_id: "prio-check".to_owned(),
        })
        .expect("submit cancel");

    // Provider resumes reading: big data frame first (already in flight,
    // non-preemptive), then the CANCEL overtakes the queued data frame.
    let first = provider.next_text().await;
    assert!(first.len() > 20 * 1024 * 1024, "first frame is the big one");
    let second = provider.next_json().await;
    assert_eq!(
        second["type"], "cancel",
        "control must overtake queued data"
    );
    assert_eq!(second["request_id"], "prio-check");
    let third = provider.next_json().await;
    assert_eq!(third["marker"], "d2");

    for wire in [big_wire, cancel_wire, d2_wire] {
        wire.await.expect("writer alive").expect("on wire");
    }

    harness.runtime.shutdown().await;
}

#[tokio::test]
async fn full_data_lane_gates_admission_until_drained() {
    let harness = Harness::start().await;
    let mut provider = FakeProvider::connect(&harness, "SER-LANE").await;
    provider.establish(false).await;
    provider.send_heartbeat(MODEL, "running").await;
    let grant = harness.admit_until_grant(ALIAS).await;

    // Pin the writer with a large frame while the provider is not reading,
    // then fill the data lane to its cap (4).
    let big = {
        let mut json = String::with_capacity(24 * 1024 * 1024 + 64);
        json.push_str(r#"{"type":"noop","pad":""#);
        json.push_str(&"b".repeat(24 * 1024 * 1024));
        json.push_str("\"}");
        Bytes::from(json)
    };
    let mut wires = vec![grant
        .session
        .submit_data(DataFrame::RawJson(big))
        .expect("big frame")];
    tokio::time::sleep(Duration::from_millis(150)).await;
    loop {
        match grant
            .session
            .submit_data(DataFrame::RawJson(Bytes::from_static(
                b"{\"type\":\"noop\"}",
            ))) {
            Ok(wire) => wires.push(wire),
            Err(SubmitError::LaneFull) => break,
            Err(SubmitError::Closed) => panic!("session closed unexpectedly"),
        }
    }

    // Full data lane -> temporarily ineligible (plan §9.4.2): RetryAfter.
    match harness.admit_once(ALIAS).await {
        AdmitOutcome::RetryAfter { .. } => {}
        other => panic!(
            "expected retry while data lane full, got {}",
            outcome_kind(&other)
        ),
    }

    // Drain: the provider reads everything; headroom and admission return.
    let drained = wires.len();
    for _ in 0..drained {
        let _ = provider.next_text().await;
    }
    for wire in wires {
        wire.await.expect("writer alive").expect("on wire");
    }
    let _ = harness.admit_until_grant(ALIAS).await;

    harness.runtime.shutdown().await;
}
