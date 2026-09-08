//! Non-streaming chat-completions scenarios through the real router:
//! sealed-sender request/response round trip and delta aggregation with
//! authoritative terminal usage (plan §22.3 style — no real DB, no real
//! fleet).

use tower::ServiceExt;
use uuid::Uuid;

use darkbloom_core::ids::LeaseId;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::crypto::sealed_sender;
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame};

use crate::support::http::*;

// -------------------------------------------------------------------
// (f) sealed request/response round trip (non-streaming)
// -------------------------------------------------------------------

#[tokio::test]
async fn sealed_round_trip_non_streaming() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, _) = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease, 20))
            .await
            .expect("prepared");
        let _ = expect_control_start(provider.expect_control().await);
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("sealed!").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("chunk");
        let terminal = completed_terminal(scope_with_lease(&prepare, lease), "prov", 1, 1);
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
        let _ = provider.expect_control().await; // ack
    });

    // Client-side sealing.
    let (_, client_secret) = nacl_box::generate_keypair();
    let kid = sealed_sender::derive_kid(&h.coordinator_public);
    let plaintext = serde_json::to_vec(&chat_body(false)).unwrap();
    let envelope =
        sealed_sender::seal_request(&plaintext, &h.coordinator_public, &kid, &client_secret)
            .expect("seal request");
    let request = axum::http::Request::builder()
        .method("POST")
        .uri("/v1/chat/completions")
        .header("authorization", format!("Bearer {API_TOKEN}"))
        .header("content-type", sealed_sender::SEALED_CONTENT_TYPE)
        .body(axum::body::Body::from(
            serde_json::to_vec(&envelope).unwrap(),
        ))
        .unwrap();

    let response = h.router.clone().oneshot(request).await.expect("router");
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers().get("content-type").unwrap(),
        sealed_sender::SEALED_CONTENT_TYPE
    );
    let body = read_body(response).await;
    let sealed_envelope: sealed_sender::SealedResponseEnvelope =
        serde_json::from_slice(&body).expect("sealed envelope");
    let opened = sealed_sender::open_response(
        &sealed_envelope,
        &h.coordinator_public,
        &client_secret,
        &kid,
    )
    .expect("open response");
    let parsed: serde_json::Value = serde_json::from_slice(&opened).expect("json");
    assert_eq!(parsed["object"], "chat.completion");
    assert_eq!(parsed["model"], PUBLIC_MODEL);
    assert_eq!(parsed["choices"][0]["message"]["content"], "sealed!");
    assert_eq!(parsed["usage"]["completion_tokens"], 1);

    script.await.expect("script");
}

// -------------------------------------------------------------------
// (i) non-streaming aggregation
// -------------------------------------------------------------------

#[tokio::test]
async fn non_streaming_aggregates_deltas_and_terminal_usage() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, _) = expect_v2_prepare(provider.expect_data().await);
        let lease = LeaseId::new(Uuid::new_v4());
        attach
            .events
            .send(prepared_event(&prepare, lease, 20))
            .await
            .expect("prepared");
        let _ = expect_control_start(provider.expect_control().await);
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("started");
        for (i, text) in ["Hello", " world"].iter().enumerate() {
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider
                        .seal_v2_chunk(&coordinator_public, content_chunk(text).as_bytes()),
                    sequence: (i + 1) as u64,
                    cumulative_tokens: (i + 1) as u64,
                })
                .expect("chunk");
        }
        // Finish chunk (empty delta + finish_reason) rides the same pipe.
        let finish = format!(
            r#"{{"id":"chatcmpl-p","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{}},"finish_reason":"stop"}}],"usage":null}}"#
        );
        attach
            .chunks
            .try_send(ChunkFrame {
                payload: provider.seal_v2_chunk(&coordinator_public, finish.as_bytes()),
                sequence: 3,
                cumulative_tokens: 2,
            })
            .expect("finish chunk");
        let terminal = completed_terminal(scope_with_lease(&prepare, lease), "prov", 2, 3);
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("terminal");
        let _ = provider.expect_control().await; // ack
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(false)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    let body = read_body(response).await;
    let parsed: serde_json::Value = serde_json::from_slice(&body).expect("json");
    assert_eq!(parsed["object"], "chat.completion");
    assert_eq!(parsed["model"], PUBLIC_MODEL);
    assert_eq!(parsed["choices"][0]["message"]["role"], "assistant");
    assert_eq!(parsed["choices"][0]["message"]["content"], "Hello world");
    assert_eq!(parsed["choices"][0]["finish_reason"], "stop");
    assert_eq!(parsed["usage"]["prompt_tokens"], 6);
    assert_eq!(parsed["usage"]["completion_tokens"], 2);
    assert_eq!(parsed["se_signature"], "test-signature");

    script.await.expect("script");
}
