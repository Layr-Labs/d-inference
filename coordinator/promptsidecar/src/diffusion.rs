//! Native diffusion prompt controls; this module never selects an AR sampler.

use crate::normalize::NormalizeError;
use serde_json::{Map, Value};

/// Mirror DiffusionGemmaReasoningControl and the provider template-context
/// precedence. Explicit booleans win; positive efforts select native thinking,
/// not different denoising depths. Absence leaves the checkpoint default alone.
pub(crate) fn apply_reasoning(
    model_type: Option<&str>,
    context: &mut Map<String, Value>,
) -> Result<(), NormalizeError> {
    if model_type != Some("diffusion_gemma") || context.contains_key("enable_thinking") {
        return Ok(());
    }
    let Some(effort) = context.get("reasoning_effort").and_then(Value::as_str) else {
        return Ok(());
    };
    let enabled = match effort.trim().to_ascii_lowercase().as_str() {
        "none" | "off" | "0" => false,
        "minimal" | "low" | "medium" | "high" | "xhigh" => true,
        _ => return Err(NormalizeError::InvalidMessages),
    };
    context.insert("enable_thinking".into(), Value::Bool(enabled));
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::normalize::normalize;
    use serde_json::{Value, json};

    #[test]
    fn positive_effort_enables_the_native_binary_thinking_switch() {
        for effort in ["minimal", "low", "medium", "high", "xhigh", " Medium "] {
            for key in ["reasoning", "reasoning_effort"] {
                let mut body =
                    json!({"model":"fixture", "messages":[{"role":"user","content":"hello"}]})
                        .as_object()
                        .unwrap()
                        .clone();
                body.insert(
                    key.into(),
                    if key == "reasoning" {
                        json!({"effort":effort})
                    } else {
                        json!(effort)
                    },
                );
                let result = normalize(body, Some("diffusion_gemma")).unwrap();
                assert_eq!(
                    result.additional_context.get("enable_thinking"),
                    Some(&Value::Bool(true)),
                    "{key}/{effort}"
                );
            }
        }
    }

    #[test]
    fn explicit_boolean_and_absence_keep_their_contracts() {
        for enabled in [false, true] {
            let body = json!({"model":"fixture", "messages":[{"role":"user","content":"hello"}],
                "reasoning":{"enabled":enabled,"effort":"unsupported"}, "enable_thinking":!enabled})
            .as_object()
            .unwrap()
            .clone();
            let result = normalize(body, Some("diffusion_gemma")).unwrap();
            assert_eq!(
                result.additional_context.get("enable_thinking"),
                Some(&Value::Bool(enabled))
            );
        }
        let body = json!({"model":"fixture", "messages":[{"role":"user","content":"hello"}]})
            .as_object()
            .unwrap()
            .clone();
        assert!(
            !normalize(body, Some("diffusion_gemma"))
                .unwrap()
                .additional_context
                .contains_key("enable_thinking")
        );
    }

    #[test]
    fn unsupported_effort_rejects_only_the_native_family() {
        let body = json!({"model":"fixture", "messages":[{"role":"user","content":"hello"}],
            "reasoning":{"effort":"unsupported"}})
        .as_object()
        .unwrap()
        .clone();
        assert!(normalize(body.clone(), Some("diffusion_gemma")).is_err());
        for kind in [None, Some("llama"), Some("gemma4")] {
            let result = normalize(body.clone(), kind).unwrap();
            assert!(!result.additional_context.contains_key("enable_thinking"));
        }
    }
}
