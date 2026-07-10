//! In-process mock provider for warm-plane E2E without Swift/MLX.
//!
//! Exercises FleetActor admit → MemoryLedger reserve/settle → LeaseState
//! prepare/start/emit/terminal. Not a substitute for dual-stack protocol-v2.

use darkbloom_core::admission::DispatchPermit;
use darkbloom_core::{AttemptId, JobId, LeaseEvent, LeaseId, LeaseState, MicroUsd};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::ledger::{MemoryLedger, OperationKey};

#[derive(Debug)]
pub struct MockCompletion {
    pub job_id: String,
    pub attempt_id: String,
    pub provider_id: String,
    pub model: String,
    pub content: String,
    pub prompt_tokens: i32,
    pub completion_tokens: i32,
    pub reserved: MicroUsd,
    pub charged: MicroUsd,
    pub terminal_digest: String,
    pub mode: String,
}

/// Complete a job that was already reserved + start-authorized by the caller.
///
/// `billable_cap_micro_usd` caps the charge at the chunk-pipe accepted output
/// (plan §10.6). Pass `None` to charge the full reported amount.
pub fn complete_authorized_job(
    ledger: &mut MemoryLedger,
    account: &str,
    job_id: &str,
    permit: &DispatchPermit,
    lease_id: &str,
    user_text: &str,
    mode: &str,
    billable_cap_micro_usd: Option<i64>,
) -> Result<MockCompletion, String> {
    let attempt_id = permit.attempt.as_str().to_string();
    ledger.record_attempt(&attempt_id, job_id, &permit.provider_id, "started");

    let lease = LeaseState::Idle
        .transition(LeaseEvent::BeginPrepare {
            job: JobId::new(job_id.to_string()),
            attempt: AttemptId::new(attempt_id.clone()),
        })
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::MarkPrepared {
            lease: LeaseId::new(lease_id.to_string()),
            prefill_running: true,
        })
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::Start)
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::StartDurable)
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::BeginEmit)
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::JournalTerminal)
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::AckTerminal)
        .map_err(|e| e.to_string())?;
    assert_eq!(lease, LeaseState::Acknowledged);

    let content = format!(
        "[{mode}] provider={} model={} echo={}",
        permit.provider_id,
        permit.model,
        user_text.chars().take(64).collect::<String>()
    );
    let completion_tokens = (content.len() / 4).max(1) as i32;
    let charged = 1_000i64;
    let terminal_digest = format!("sha256:{}", Uuid::new_v4());
    let cap = billable_cap_micro_usd.unwrap_or(charged);
    ledger
        .settle_capped(
            OperationKey(format!("settle:{job_id}")),
            job_id,
            account,
            charged,
            cap,
            &terminal_digest,
        )
        .map_err(|e| e.to_string())?;

    let reserved = ledger
        .job_reserved_total(job_id)
        .unwrap_or(MicroUsd(0));
    let actual_charged = charged.min(cap).max(0);

    Ok(MockCompletion {
        job_id: job_id.to_string(),
        attempt_id,
        provider_id: permit.provider_id.clone(),
        model: permit.model.clone(),
        content,
        prompt_tokens: (user_text.len() / 4).max(1) as i32,
        completion_tokens,
        reserved,
        charged: MicroUsd(actual_charged),
        terminal_digest,
        mode: mode.to_string(),
    })
}

/// Standalone mock path used by unit tests (reserve → authorize → complete).
pub fn run_mock_completion(
    ledger: &mut MemoryLedger,
    account: &str,
    permit: &DispatchPermit,
    user_text: &str,
) -> Result<MockCompletion, String> {
    let job_id = format!("job-{}", Uuid::new_v4());
    let lease_id = format!("lease-{}", Uuid::new_v4());
    let reserve_amount = 100_000i64;
    let res = ledger
        .reserve(
            OperationKey(format!("reserve:{job_id}")),
            &job_id,
            account,
            reserve_amount,
        )
        .map_err(|e| e.to_string())?;
    let _ = res;
    ledger
        .mark_start_authorized(&job_id)
        .map_err(|e| e.to_string())?;
    complete_authorized_job(
        ledger,
        account,
        &job_id,
        permit,
        &lease_id,
        user_text,
        "rust-mock",
        None,
    )
}

pub fn openai_chat_response(c: &MockCompletion, stream: bool) -> Value {
    if stream {
        return json!({
            "id": c.job_id,
            "object": "chat.completion.chunk",
            "model": c.model,
            "choices": [{
                "index": 0,
                "delta": { "content": c.content },
                "finish_reason": "stop"
            }]
        });
    }
    json!({
        "id": c.job_id,
        "object": "chat.completion",
        "model": c.model,
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": c.content },
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": c.prompt_tokens,
            "completion_tokens": c.completion_tokens,
            "total_tokens": c.prompt_tokens + c.completion_tokens
        },
        "darkbloom": {
            "provider_id": c.provider_id,
            "attempt_id": c.attempt_id,
            "charged_micro_usd": c.charged.0,
            "reserved_micro_usd": c.reserved.0,
            "terminal_digest": c.terminal_digest,
            "mode": c.mode
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use darkbloom_core::admission::DispatchPermit;
    use std::time::Duration;

    #[test]
    fn mock_completion_conserves_money() {
        let mut led = MemoryLedger::default();
        led.credit("acct", 1_000_000, 0).unwrap();
        let permit = DispatchPermit {
            attempt: AttemptId::new("a1"),
            provider_id: "p1".into(),
            model: "m".into(),
            expires_after: Duration::from_secs(2),
        };
        let c = run_mock_completion(&mut led, "acct", &permit, "hello").unwrap();
        assert!(c.content.contains("hello"));
        let (bal, _) = led.balance("acct");
        // reserved 100_000 then settled charging 1_000 → refund 99_000 → net -1_000
        assert_eq!(bal, 1_000_000 - 1_000);
        assert_eq!(led.active_job_count(), 0);
    }
}
