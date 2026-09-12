//! Mirror Qwen35TemplateFix and GPTOSSHarmonyTemplateFix leading-system folding. In particular,
//! service-injected response-format instructions must be folded together with
//! caller system turns before Qwen's single-system template is rendered.

use serde_json::Value;

pub(crate) fn qwen_applies(model_id: &str, model_type: Option<&str>) -> bool {
    let kind = model_type.unwrap_or_default().trim().to_lowercase();
    if ["qwen3_5", "qwen3_5_moe", "qwen3_vl_moe"].contains(&kind.as_str()) {
        return true;
    }
    let id = model_id.to_lowercase();
    [
        "qwen3.5", "qwen3_5", "qwen3.6", "qwen3_6", "qwen3.8", "qwen3_8", "qwen3-vl", "qwen3_vl",
    ]
    .iter()
    .any(|needle| id.contains(needle))
}

pub(crate) fn normalize_messages(messages: Vec<Value>) -> Vec<Value> {
    let is_system =
        |message: &&Value| message.get("role").and_then(Value::as_str) == Some("system");
    let systems = messages.iter().filter(is_system).collect::<Vec<_>>();
    let Some(first) = systems.first() else {
        return messages;
    };
    if systems.len() == 1 && messages.first() == Some(first) {
        return messages;
    }
    let mut leading = (*first).clone();
    if systems.len() > 1 {
        // template_messages already lowers supported text parts to strings.
        // Refuse a shape drift instead of silently dropping structured data.
        let Some(texts) = systems
            .iter()
            .map(|message| message.get("content").and_then(Value::as_str))
            .collect::<Option<Vec<_>>>()
        else {
            return messages;
        };
        leading["content"] = Value::String(
            texts
                .into_iter()
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n\n"),
        );
    }
    std::iter::once(leading)
        .chain(
            messages
                .into_iter()
                .filter(|message| message.get("role").and_then(Value::as_str) != Some("system")),
        )
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn leading_fold_preserves_first_metadata_and_non_system_order() {
        let result = normalize_messages(vec![
            json!({"role":"user","content":"q"}),
            json!({"role":"system","content":"one","name":"first"}),
            json!({"role":"assistant","content":"a"}),
            json!({"role":"system","content":""}),
            json!({"role":"system","content":"two","name":"last"}),
        ]);
        assert_eq!(
            result,
            vec![
                json!({"role":"system","content":"one\n\ntwo","name":"first"}),
                json!({"role":"user","content":"q"}),
                json!({"role":"assistant","content":"a"})
            ]
        );
        assert!(qwen_applies("EigenLabs/Qwen3.8-27B-4bit-mtp", None));
        assert!(qwen_applies("other", Some(" qwen3_vl_moe ")));
        assert!(!qwen_applies("gemma", Some("gemma4")));
    }
}
