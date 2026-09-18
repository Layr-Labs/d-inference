use promptsidecar::normalize::normalize;
use serde_json::{Value, json};

#[test]
fn shared_parallel_tool_instructions_match_provider_contract() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../fixtures/prompt-contract/v1/tool_choice_parallel_vectors.json"
    ))
    .unwrap();
    assert_eq!(cases.len(), 16);
    for case in cases {
        let mut body = json!({
            "model": "DarkBloom/Qwen3.8-Flash-Next-Q4-mtp",
            "reasoning": {"enabled": true, "effort": "low"},
            "messages": [
                {"role": "system", "content": "System policy."},
                {"role": "user", "content": "Please look up the independent requests."}
            ],
            "tools": case["tool_names"].as_array().unwrap().iter().map(|name| json!({
                "type": "function",
                "function": {"name": name, "parameters": {"type": "object", "properties": {}}}
            })).collect::<Vec<_>>(),
            "tool_choice": case["tool_choice"]
        });
        if let Some(parallel) = case.get("parallel_tool_calls") {
            body["parallel_tool_calls"] = parallel.clone();
        }
        // The frozen instruction corpus remains the exact legacy contract.
        // Native Qwen4 prompt ownership has separate paired tests.
        let normalized =
            normalize(body.as_object().unwrap().clone(), Some("qwen4_exp_text")).unwrap();
        assert_eq!(
            Value::Object(normalized.additional_context.clone()),
            json!({"enable_thinking": true, "reasoning_effort": "low"}),
            "{}",
            case["name"]
        );
        let instruction = case["expected_instruction"].as_str();
        let expected_system = instruction.map_or_else(
            || "System policy.".to_owned(),
            |text| format!("System policy.\n\n{text}"),
        );
        let expected_user = if case["repeat_user"] == true {
            format!(
                "Please look up the independent requests.\n\n{}",
                instruction.unwrap()
            )
        } else {
            "Please look up the independent requests.".to_owned()
        };
        assert_eq!(normalized.messages.len(), 2, "{}", case["name"]);
        assert_eq!(
            normalized.messages[0]["content"], expected_system,
            "{}",
            case["name"]
        );
        assert_eq!(
            normalized.messages[1]["content"], expected_user,
            "{}",
            case["name"]
        );
        let tool_names: Vec<_> = normalized
            .tools
            .unwrap_or_default()
            .iter()
            .map(|tool| tool["function"]["name"].clone())
            .collect();
        assert_eq!(
            tool_names,
            *case["expected_tool_names"].as_array().unwrap(),
            "{}",
            case["name"]
        );
    }
}
