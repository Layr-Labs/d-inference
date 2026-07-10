//! Live provider_terminal binding checks (DECISIONS #48).

use serde_json::Value;

/// Validate a live provider_terminal against the funded attempt.
/// Returns `(terminal_digest, prompt_tokens, completion_tokens)`.
pub fn validate_provider_terminal(
    terminal: &Value,
    job_id: &str,
    attempt_id: &str,
    lease_id: &str,
    coordinator_epoch: u64,
    dispatch_nonce: &str,
    request_digest: &str,
) -> Result<(String, i32, i32), String> {
    let digest = terminal
        .get("terminal_digest")
        .and_then(|d| d.as_str())
        .unwrap_or("")
        .to_string();
    if digest.is_empty() {
        return Err("missing terminal_digest".into());
    }
    let require_str = |key: &str, expected: &str| -> Result<(), String> {
        match terminal.get(key).and_then(|v| v.as_str()) {
            Some(got) if got == expected => Ok(()),
            Some(got) => Err(format!("{key} mismatch: got {got}, expected {expected}")),
            None => Err(format!("missing {key}")),
        }
    };
    require_str("job_id", job_id)?;
    require_str("attempt_id", attempt_id)?;
    require_str("lease_id", lease_id)?;
    require_str("dispatch_nonce", dispatch_nonce)?;
    require_str("request_digest", request_digest)?;
    match terminal.get("coordinator_epoch").and_then(|v| v.as_u64()) {
        Some(got) if got == coordinator_epoch => {}
        Some(got) => {
            return Err(format!(
                "coordinator_epoch mismatch: got {got}, expected {coordinator_epoch}"
            ));
        }
        None => return Err("missing coordinator_epoch".into()),
    }
    let prompt_tokens = terminal
        .get("prompt_tokens")
        .and_then(|t| t.as_i64())
        .ok_or_else(|| "missing prompt_tokens".to_string())?;
    let completion_tokens = terminal
        .get("completion_tokens")
        .and_then(|t| t.as_i64())
        .ok_or_else(|| "missing completion_tokens".to_string())?;
    if prompt_tokens < 0 || completion_tokens < 0 {
        return Err("negative token counts".into());
    }
    Ok((digest, prompt_tokens as i32, completion_tokens as i32))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn good() -> Value {
        json!({
            "type": "provider_terminal",
            "job_id": "j1",
            "attempt_id": "a1",
            "lease_id": "l1",
            "coordinator_epoch": 7,
            "dispatch_nonce": "n1",
            "request_digest": "sha256:req",
            "terminal_digest": "sha256:term",
            "prompt_tokens": 4,
            "completion_tokens": 8,
            "outcome": "completed"
        })
    }

    #[test]
    fn accepts_bound_terminal() {
        let (d, p, c) =
            validate_provider_terminal(&good(), "j1", "a1", "l1", 7, "n1", "sha256:req").unwrap();
        assert_eq!(d, "sha256:term");
        assert_eq!(p, 4);
        assert_eq!(c, 8);
    }

    #[test]
    fn rejects_job_mismatch() {
        let err =
            validate_provider_terminal(&good(), "j-other", "a1", "l1", 7, "n1", "sha256:req")
                .unwrap_err();
        assert!(err.contains("job_id mismatch"));
    }

    #[test]
    fn rejects_missing_digest() {
        let mut t = good();
        t.as_object_mut().unwrap().remove("terminal_digest");
        let err = validate_provider_terminal(&t, "j1", "a1", "l1", 7, "n1", "sha256:req")
            .unwrap_err();
        assert!(err.contains("missing terminal_digest"));
    }

    #[test]
    fn rejects_negative_tokens() {
        let mut t = good();
        t["completion_tokens"] = json!(-1);
        let err = validate_provider_terminal(&t, "j1", "a1", "l1", 7, "n1", "sha256:req")
            .unwrap_err();
        assert!(err.contains("negative"));
    }

    #[test]
    fn rejects_epoch_mismatch() {
        let err =
            validate_provider_terminal(&good(), "j1", "a1", "l1", 99, "n1", "sha256:req")
                .unwrap_err();
        assert!(err.contains("coordinator_epoch mismatch"));
    }
}
