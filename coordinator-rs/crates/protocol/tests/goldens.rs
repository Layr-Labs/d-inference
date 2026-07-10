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
