use promptsidecar::normalize::normalize;
use serde_json::{Value, json};

#[test]
fn shared_native_reasoning_context_vectors() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../fixtures/prompt-contract/v1/native_reasoning_vectors.json"
    ))
    .unwrap();
    assert_eq!(cases.len(), 25);
    for case in cases {
        let result = normalize(
            case["request"].as_object().unwrap().clone(),
            case["model_type"].as_str(),
        );
        if case["error"] == true {
            assert!(result.is_err(), "{}", case["name"]);
        } else {
            assert_eq!(
                Value::Object(result.unwrap().additional_context),
                case["additional_context"],
                "{}",
                case["name"]
            );
        }
    }
}

#[test]
fn shared_forced_tool_thinking_vectors() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../../fixtures/prompt-contract/v1/forced_tool_thinking_vectors.json"
    ))
    .unwrap();
    assert_eq!(cases.len(), 18);
    for case in cases {
        let request = normalize(
            case["request"].as_object().unwrap().clone(),
            case["model_type"].as_str(),
        )
        .unwrap();
        assert_eq!(
            request.additional_context["enable_thinking"], case["enable_thinking"],
            "{}",
            case["name"]
        );
        assert_eq!(request.additional_context["preserve_thinking"], json!(true));
    }
}
