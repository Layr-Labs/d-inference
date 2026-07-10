//! v1 chat-completions scenario through the real router: golden wire
//! shape against the fixture vectors, chunk decrypt, and settlement from
//! the provider-reported usage (plan §22.3 style — no real DB, no real
//! fleet).

#[path = "http_support/mod.rs"]
mod support;

use tower::ServiceExt;

use darkbloom_core::money::Tokens;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::json_v1::UsageInfo;
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, DataFrame, ProtocolGen};

use support::*;

// -------------------------------------------------------------------
// (j) v1 happy path: golden wire shape, chunk decrypt, settle from usage
// -------------------------------------------------------------------

#[tokio::test]
async fn v1_happy_path_golden_wire_and_settle() {
    let mut h = HarnessBuilder::new()
        .providers(vec![ProtocolGen::V1])
        .build();
    let mut provider = h.providers.remove(0);

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let frame = provider.expect_data().await;
        let bytes = match frame {
            DataFrame::V1InferenceRequest(bytes) => bytes,
            other => panic!("expected v1 inference_request, got {other:?}"),
        };
        let wire: serde_json::Value = serde_json::from_slice(&bytes).expect("wire json");

        // Golden shape: same key structure as the fixture vectors.
        let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/vectors/json_v1/inference_request__encrypted.json"
        )))
        .expect("fixture");
        let wire_keys: Vec<&str> = wire
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        let fixture_keys: Vec<&str> = fixture
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(wire_keys, fixture_keys, "top-level key set matches golden");
        assert_eq!(wire["type"], "inference_request");
        assert_eq!(wire["request_id"], attach.wire_id.as_str());
        // Zero-valued `body` is ALWAYS on the wire (Go omitempty is a no-op
        // on struct fields; the Swift strict decoder depends on it).
        assert_eq!(wire["body"], fixture["body"]);
        let encrypted_keys: Vec<&str> = wire["encrypted_body"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(encrypted_keys, vec!["ciphertext", "ephemeral_public_key"]);

        // Decrypt the body like the provider would.
        let session_public_b64 = wire["encrypted_body"]["ephemeral_public_key"]
            .as_str()
            .unwrap()
            .to_owned();
        let payload = darkbloom_protocol::json_v1::EncryptedPayload {
            ephemeral_public_key: session_public_b64.clone(),
            ciphertext: wire["encrypted_body"]["ciphertext"]
                .as_str()
                .unwrap()
                .to_owned(),
        };
        let plain = nacl_box::open(&payload, &provider.secret).expect("decrypt v1 body");
        let body: serde_json::Value = serde_json::from_slice(&plain).expect("body json");
        assert_eq!(body["model"], CONCRETE_MODEL);
        assert_eq!(body["stream"], true);

        // Accepted → encrypted chunks (v1 style: `data: ` prefix baked in,
        // sealed back to the session key) → complete with usage.
        attach
            .events
            .send(AttemptEvent::AcceptedV1)
            .await
            .expect("accepted");
        for text in ["Hello", " v1"] {
            let plaintext = format!("data: {}", content_chunk(text));
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider.seal_v1_chunk(&session_public_b64, plaintext.as_bytes()),
                    sequence: 0,
                    cumulative_tokens: 0,
                })
                .expect("chunk");
        }
        attach
            .events
            .send(AttemptEvent::CompleteV1 {
                usage: Some(UsageInfo {
                    prompt_tokens: 6,
                    completion_tokens: 9,
                    reasoning_tokens: 2,
                }),
                se_signature: Some("v1-sig".to_owned()),
                response_hash: Some("v1-hash".to_owned()),
            })
            .await
            .expect("complete");
    });

    let response = h
        .router
        .clone()
        .oneshot(chat_request(&chat_body(true)))
        .await
        .expect("router");
    assert_eq!(response.status(), 200);
    let body = read_body(response).await;
    let events = sse_events(&body);
    assert_eq!(
        events[0],
        content_chunk("Hello").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    assert_eq!(
        events[1],
        content_chunk(" v1").replace(CONCRETE_MODEL, PUBLIC_MODEL)
    );
    let usage: serde_json::Value = serde_json::from_str(&events[2]).expect("usage json");
    assert_eq!(usage["usage"]["prompt_tokens"], 6);
    assert_eq!(usage["usage"]["completion_tokens"], 9);
    assert_eq!(
        usage["usage"]["completion_tokens_details"]["reasoning_tokens"],
        2
    );
    assert_eq!(usage["se_signature"], "v1-sig");
    assert_eq!(events[3], "[DONE]");

    script.await.expect("script");

    // v1 runs the SAME durable funding leg as v2, with facts frozen from
    // the reserve estimates (module docs): the resize is money-neutral but
    // records terms + start_authorized. Settlement's prompt claim echoes
    // the frozen estimate (5 = 22 content bytes / 4), never the provider's
    // self-reported count; the checkpoint promotes to the claimed
    // completion on an intact stream.
    let names: Vec<&str> = h.ledger.snapshot().iter().map(call_name).collect();
    assert_eq!(names, vec!["reserve", "resize", "mark_running", "settle"]);
    let resize = h.ledger.find_resize().expect("resize");
    assert_eq!(resize.frozen.billable_input_tokens, Tokens::new(5));
    assert_eq!(resize.frozen.max_output_tokens, Tokens::new(64));
    let settle = h.ledger.find_settle().unwrap();
    assert_eq!(settle.completion_tokens_claimed, 9);
    assert_eq!(
        settle.accepted_cumulative_tokens, 9,
        "intact stream promotes checkpoint"
    );
    assert_eq!(
        settle.prompt_tokens, 5,
        "v1 bills the frozen estimate, not the provider claim"
    );
}
