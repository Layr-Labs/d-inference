//! In-process mock provider for warm-plane E2E without Swift/MLX.
//!
//! Exercises FleetActor admit → MemoryLedger reserve/release → LeaseState
//! prepare/start/emit/terminal. Not a substitute for dual-stack protocol-v2.

use darkbloom_core::{
    AttemptId, JobId, LeaseEvent, LeaseId, LeaseState, MicroUsd,
};
use darkbloom_core::admission::DispatchPermit;
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
}

pub fn run_mock_completion(
    ledger: &mut MemoryLedger,
    account: &str,
    permit: &DispatchPermit,
    user_text: &str,
) -> Result<MockCompletion, String> {
    let job_id = format!("job-{}", Uuid::new_v4());
    let attempt_id = permit.attempt.as_str().to_string();
    let lease_id = format!("lease-{}", Uuid::new_v4());

    // Provisional reservation (anti-abuse upper bound for pilot).
    let reserve_amount = 100_000i64; // $0.10
    let res = ledger
        .reserve(
            OperationKey(format!("reserve:{job_id}")),
            &job_id,
            account,
            reserve_amount,
        )
        .map_err(|e| e.to_string())?;

    let lease = LeaseState::Idle
        .transition(LeaseEvent::BeginPrepare {
            job: JobId::new(job_id.clone()),
            attempt: AttemptId::new(attempt_id.clone()),
        })
        .map_err(|e| e.to_string())?
        .transition(LeaseEvent::MarkPrepared {
            lease: LeaseId::new(lease_id.clone()),
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
        "[rust-mock] provider={} model={} echo={}",
        permit.provider_id,
        permit.model,
        user_text.chars().take(64).collect::<String>()
    );
    let completion_tokens = (content.len() / 4).max(1) as i32;
    let charged = 1_000i64; // $0.001 mock charge
    // Release unused reservation provenance exactly via release then re-debit charge.
    let _ = ledger
        .release(OperationKey(format!("release:{job_id}")), &job_id, account)
        .map_err(|e| e.to_string())?;
    // Charge actual (simplified: debit total only for mock).
    let charge = ledger.reserve(
        OperationKey(format!("charge:{job_id}")),
        &format!("charge-{job_id}"),
        account,
        charged,
    );
    if let Err(err) = charge {
        return Err(err.to_string());
    }

    Ok(MockCompletion {
        job_id,
        attempt_id,
        provider_id: permit.provider_id.clone(),
        model: permit.model.clone(),
        content,
        prompt_tokens: (user_text.len() / 4).max(1) as i32,
        completion_tokens,
        reserved: res.provenance.total,
        charged: MicroUsd(charged),
    })
}

pub fn openai_chat_response(c: &MockCompletion, stream: bool) -> Value {
    if stream {
        // Caller should SSE; this returns the final chunk payload for tests.
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
            "mode": "mock_prepare_start"
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
        led.credit("acct", 1_000_000, 0);
        let permit = DispatchPermit {
            attempt: AttemptId::new("a1"),
            provider_id: "p1".into(),
            model: "m".into(),
            expires_after: Duration::from_secs(2),
        };
        let c = run_mock_completion(&mut led, "acct", &permit, "hello").unwrap();
        assert!(c.content.contains("hello"));
        let (bal, _) = led.balance("acct");
        assert_eq!(bal, 1_000_000 - 1_000);
    }
}
