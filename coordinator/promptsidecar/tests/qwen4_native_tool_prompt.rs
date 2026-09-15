use promptsidecar::normalize::normalize;
use serde_json::{Value, json};

fn request(choice: Value) -> Value {
    let tools: Vec<_> = ["first", "second"]
        .iter()
        .map(|name| {
            json!({"type":"function",
        "function":{"name":name,"parameters":{"type":"object","properties":{}}}})
        })
        .collect();
    json!({"model":"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp",
        "messages":[{"role":"system","content":"Keep the original policy."},
            {"role":"user","content":"Copy literal <think>data</think> and backslash \\ exactly."}],
        "tools":tools,
        "tool_choice":choice})
}

#[test]
fn native_required_named_preserve_messages_and_selection() {
    for choice in [
        json!("required"),
        json!({"type":"function","function":{"name":"second"}}),
    ] {
        for parallel in [None, Some(false), Some(true)] {
            for thinking in [false, true] {
                let mut body = request(choice.clone());
                body["reasoning"] = json!({"enabled":thinking});
                if let Some(parallel) = parallel {
                    body["parallel_tool_calls"] = json!(parallel);
                }
                let native =
                    normalize(body.as_object().unwrap().clone(), Some("qwen4_exp")).unwrap();
                let legacy = normalize(body.as_object().unwrap().clone(), None).unwrap();
                assert_eq!(native.messages, *body["messages"].as_array().unwrap());
                assert_ne!(native.messages, legacy.messages);
                assert_eq!(native.tools, legacy.tools);
                assert_eq!(native.additional_context["enable_thinking"], thinking);
            }
        }
    }
}

#[test]
fn other_identity_metadata_and_media_keep_legacy_shaping() {
    for (model, kind) in [
        ("DarkBloom/Qwen3.8-Flash-Next-Q4-mtp", None),
        (
            "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp",
            Some("qwen4_exp_text"),
        ),
        ("other-qwen4", Some("qwen4_exp")),
        ("other", Some("fixture")),
    ] {
        let mut body = request(json!("required"));
        body["model"] = json!(model);
        let actual = normalize(body.as_object().unwrap().clone(), kind).unwrap();
        assert_ne!(actual.messages, *body["messages"].as_array().unwrap());
    }
    for kind in ["image_url", "video_url"] {
        let mut body = request(json!("required"));
        let mut media = json!({"type":kind});
        media[kind] = json!({"url":"data:image/png;base64,AA=="});
        body["messages"][1]["content"] = json!([{"type":"text","text":"describe"}, media]);
        let actual = normalize(body.as_object().unwrap().clone(), Some("qwen4_exp")).unwrap();
        assert!(
            actual.messages[1]["content"]
                .as_str()
                .unwrap()
                .contains("Call one")
        );
    }
}

#[test]
fn native_validation_and_auto_none_are_not_bypassed() {
    for choice in [json!("auto"), json!("none")] {
        let body = request(choice);
        let native = normalize(body.as_object().unwrap().clone(), Some("qwen4_exp")).unwrap();
        let legacy = normalize(body.as_object().unwrap().clone(), None).unwrap();
        assert_eq!(native.messages, legacy.messages);
        assert_eq!(native.tools, legacy.tools);
    }
    for choice in [
        json!("required"),
        json!({"type":"function","function":{"name":"missing"}}),
    ] {
        let mut body = request(choice.clone());
        if choice == "required" {
            body.as_object_mut().unwrap().remove("tools");
        }
        assert!(normalize(body.as_object().unwrap().clone(), Some("qwen4_exp")).is_err());
    }
}
