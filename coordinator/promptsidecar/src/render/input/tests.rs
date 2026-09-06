use super::*;
use serde_json::json;

#[test]
fn raw_numeric_bridge_domain_is_exact_or_cold() {
    for encoded in [
        "9223372036854775808",
        "18446744073709551615",
        "-9223372036854775809",
        "-0",
        "-0.0",
        "1e16",
        "-1e16",
        "1e308",
    ] {
        let value: Value = serde_json::from_str(encoded).unwrap();
        assert!(
            validate_request_input(&json!({"tools":[{"parameters":{"value":value}}]})).is_err(),
            "{encoded}"
        );
        let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":format!("{{\"value\":{encoded}}}")}}]}]});
        assert!(validate_request_input(&body).is_err(), "encoded {encoded}");
    }
    for encoded in [
        "9223372036854775807",
        "-9223372036854775808",
        "9007199254740993",
        "0",
        "1",
        "1.0",
        "1e15",
        "1e-7",
        "19.074765292284162",
        "true",
        "false",
    ] {
        let value: Value = serde_json::from_str(encoded).unwrap();
        validate_request_input(&json!({"tools":[{"parameters":{"value":value}}]})).unwrap();
        let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":format!("{{\"value\":{encoded}}}")}}]}]});
        validate_request_input(&body).unwrap();
    }
}

#[test]
fn unsupported_structured_arguments_are_cold_but_plain_text_stays_opaque() {
    for encoded in ["[]", "[1,true]", "1", "1.0", "null", "true", "\"text\""] {
        let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":encoded}}]}]});
        assert!(validate_request_input(&body).is_err(), "{encoded}");
    }
    for encoded in ["{unclosed", "[1,", " {\"v\":1e999}"] {
        let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":encoded}}]}]});
        assert!(validate_request_input(&body).is_err(), "{encoded}");
    }
    for encoded in [" ", "not JSON", "{}", "{\"v\":true}"] {
        let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":encoded}}]}]});
        validate_request_input(&body).unwrap();
    }
}

// Actual JSONValue/sendableValue and decodeToolCallArguments bridges through
// Swift-Jinja 2.3.6, with the separately tested CFBoolean fix. The intermediate
// JSONSerialization-only path is retained for provenance but is not serving.
// SHA256 628ecd501fa0179ca82b9059bcbfab14999d1367a2d00edba3dd605273e39f25.
#[test]
fn actual_raw_bridge_oracle_matches_for_every_eligible_input() {
    let rows: Value = serde_json::from_str(include_str!("swift_236_raw_bridge.json")).unwrap();
    let mut environment = minijinja::Environment::new();
    environment.add_filter("tojson", super::super::json::tojson);
    let mut compared = 0;
    let mut cold = 0;
    let mut intermediate = 0;
    let mut sanitized_or_invalid = 0;
    for row in rows.as_array().unwrap() {
        let path = row["path"].as_str().unwrap();
        if path == "JSONSerialization/Value(any:)" {
            intermediate += 1;
            continue;
        }
        let encoded = row["inputJSON"].as_str().unwrap();
        let parsed = serde_json::from_str::<Value>(encoded);
        let input = if path == "decodeToolCallArguments/Value(any:)" {
            let body = json!({"messages":[{"tool_calls":[{"function":{"arguments":encoded}}]}]});
            if validate_request_input(&body).is_err() {
                cold += 1;
                continue;
            }
            parsed.unwrap_or_else(|_| Value::String(encoded.to_owned()))
        } else {
            assert_eq!(path, "JSONValue/sendableValue");
            let Ok(input) = parsed else {
                assert!(row["error"].is_string());
                sanitized_or_invalid += 1;
                continue;
            };
            if input.is_null() {
                // Production normalization removes null before Jinja conversion.
                assert!(row["error"].is_string());
                sanitized_or_invalid += 1;
                continue;
            }
            if validate_request_input(&input).is_err() {
                cold += 1;
                continue;
            }
            input
        };
        let actual = environment
            .render_str("{{ value|tojson }}", json!({"value":input}))
            .unwrap();
        assert_eq!(
            actual,
            row["output"].as_str().unwrap(),
            "{} {path}",
            row["id"]
        );
        compared += 1;
    }
    assert_eq!(rows.as_array().unwrap().len(), 66);
    assert_eq!(intermediate, 22);
    assert_eq!(sanitized_or_invalid, 2);
    assert!(compared >= 20);
    assert!(cold >= 16);
    assert_eq!(compared + cold + intermediate + sanitized_or_invalid, 66);
}

#[test]
fn nested_tool_schema_canonical_collision_fails_without_rewriting() {
    let body = json!({"model":"qwen", "messages":[{"role":"user","content":"hello"}],
        "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object",
            "properties":{"é":{"type":"string"},"e\u{301}":{"type":"integer"}}}}}]});
    let original = body.clone();
    assert!(validate_request_input(&body).is_err());
    assert_eq!(body, original);
}

#[test]
fn distinct_decomposed_keys_and_unrelated_maps_stay_eligible() {
    let body = json!({"tools":[{"parameters":{"properties":{
        "e\u{300}":{},"e\u{302}":{},"é":{},"êx":{},"e":{}}}}],
        "first":{"é":1},"second":{"e\u{301}":2},"strings":["é","e\u{301}"]});
    let original = body.clone();
    validate_request_input(&body).unwrap();
    assert_eq!(body, original);
}

#[test]
fn ascii_alias_and_non_latin_canonical_pairs_fail() {
    for (a, b) in [
        ("K", "\u{212a}"),
        ("가", "\u{1100}\u{1161}"),
        ("\u{1e0b}", "d\u{307}"),
    ] {
        let body = Value::Object(
            [(a.to_owned(), json!(1)), (b.to_owned(), json!(2))]
                .into_iter()
                .collect(),
        );
        assert!(validate_request_input(&body).is_err());
    }
}

#[test]
fn key_and_traversal_bounds_refuse_before_unbounded_normalization() {
    let body = Value::Object(
        [("a".repeat(MAX_KEY_BYTES + 1), json!(1))]
            .into_iter()
            .collect(),
    );
    assert!(validate_request_input(&body).is_err());
    assert!(visit(&json!({"é":1}), 0, &mut 10, &mut 1).is_err());
    assert!(visit(&json!([1, 2]), 0, &mut 1, &mut 100).is_err());
}

#[test]
fn encoded_tool_arguments_are_checked_before_null_sanitation() {
    let encoded = r#"{"é":null,"e\u0301":1}"#;
    for body in [
        json!({"messages":[{"tool_calls":[{"function":{"name":"f","arguments":encoded}}]}]}),
        json!({"messages":[{"function_call":{"name":"f","arguments":encoded}}]}),
        json!({"input":[{"type":"function_call","name":"f","arguments":encoded}]}),
    ] {
        assert!(validate_request_input(&body).is_err());
    }
    // Ordinary message content and strings inside argument values are not
    // JSON maps merely because their bytes happen to resemble JSON.
    validate_request_input(&json!({"messages":[{"content":encoded}]})).unwrap();
    validate_request_input(&json!({"messages":[{"tool_calls":[{"function":{"name":"f","arguments":"not { JSON é"}}]}]})).unwrap();
    validate_request_input(&json!({"messages":[{"tool_calls":[{"function":{"name":"f","arguments":r#"{"e\u0300":null,"e\u0302":1}"#}}]}]})).unwrap();
}
