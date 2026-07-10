//! Golden JSON fixtures for protocol v2 frames.

#[test]
fn prepare_golden_parses() {
    let raw = include_str!("fixtures/prepare.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "prepare");
    assert_eq!(v["session_epoch"], 3);
    assert_eq!(v["model"], "pilot-text-model");
}

#[test]
fn prepared_golden_parses() {
    let raw = include_str!("fixtures/prepared.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "prepared");
    assert_eq!(v["lease_ttl_ms"], 15000);
    assert_eq!(v["prefill_can_begin"], true);
}

#[test]
fn terminal_golden_parses() {
    let raw = include_str!("fixtures/provider_terminal.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "provider_terminal");
    assert_eq!(v["outcome"], "completed");
    assert_eq!(v["terminal_digest"], "sha256:terminal");
}

#[test]
fn start_golden_parses() {
    let raw = include_str!("fixtures/start.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "start");
    assert_eq!(v["lease_id"], "lease-33333333-3333-3333-3333-333333333333");
}

#[test]
fn abort_golden_parses() {
    let raw = include_str!("fixtures/abort.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "abort");
    assert_eq!(v["reason"], "hedge_lost");
}

#[test]
fn terminal_ack_golden_parses() {
    let raw = include_str!("fixtures/terminal_ack.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "terminal_ack");
    assert_eq!(v["disposition"], "settled");
}

#[test]
fn cancelled_golden_parses() {
    let raw = include_str!("fixtures/cancelled.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "cancelled");
    assert_eq!(v["attempt_id"], "attempt-22222222-2222-2222-2222-222222222222");
}

#[test]
fn chunk_v2_golden_parses() {
    let raw = include_str!("fixtures/chunk_v2.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "inference_response_chunk");
    assert_eq!(v["sequence"], 1);
    assert_eq!(v["completion_tokens_cumulative"], 4);
    assert_eq!(v["rolling_response_hash"], "sha256:roll1");
}

#[test]
fn model_ready_golden_parses() {
    let raw = include_str!("fixtures/model_ready.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "model_ready");
    assert_eq!(v["state_revision"], 42);
}

#[test]
fn model_gone_golden_parses() {
    let raw = include_str!("fixtures/model_gone.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "model_gone");
    assert_eq!(v["state_revision"], 43);
}

#[test]
fn structured_error_golden_parses() {
    let raw = include_str!("fixtures/structured_error.json");
    let v: serde_json::Value = serde_json::from_str(raw).unwrap();
    assert_eq!(v["type"], "structured_error");
    assert_eq!(v["class"], "security");
    assert_eq!(v["retryable"], false);
}
