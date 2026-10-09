use super::*;
use crate::api::{Endpoint, PlanRequest};
use crate::artifacts::LoadedArtifacts;
use crate::contract::{
    ContractMetadata, ContractVersions, METADATA_FILE, PromptArtifact, compute_contract_id,
};
use crate::normalize::{NormalizedRequest, normalize};
use crate::planner::{PlanError, Planner};
use crate::render::{self, RenderError};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tempfile::TempDir;

fn normalized(body: Value) -> Result<NormalizedRequest, NormalizeError> {
    normalize(body.as_object().unwrap().clone(), Some("mimo_v2"))
}
fn history(arguments: Value) -> Value {
    json!({"model":"mimo-private", "messages":[
        {"role":"assistant","content":null,"reasoning_content":"Keep &amp; e\u{301}",
         "tool_calls":[{"id":"a","type":"function","function":{"name":"old_tool","arguments":arguments}}]},
        {"role":"tool","tool_call_id":"a","content":"result"}]})
}
fn arguments(request: &NormalizedRequest) -> &Value {
    &request.messages[0]["tool_calls"][0]["function"]["arguments"]
}

#[test]
fn family_selection_is_exact_metadata_not_model_name_or_request_type() {
    for kind in [
        None,
        Some("mimo_v2_audio"),
        Some("MiMo_v2"),
        Some(" mimo_v2"),
        Some("llama"),
    ] {
        assert!(!applies(kind));
    }
    assert!(applies(Some("mimo_v2")));
    let mut body = history(json!("{\"x\":null}"));
    body["model"] = json!("XiaomiMiMo/MiMo-V2.6-Flash-RL");
    body["model_type"] = json!("mimo_v2");
    let legacy = normalize(body.as_object().unwrap().clone(), Some("llama")).unwrap();
    assert_eq!(arguments(&legacy), &json!({}));
    assert_eq!(arguments(&normalized(body).unwrap()), &json!({"x":null}));
}

#[test]
fn null_members_array_positions_and_opaque_string_bytes_survive() {
    let decoded =
        json!({"z":null,"a":[null,{"x":null},false,0,1],"literal":"null &amp;\r\n e\u{301}"});
    let value = normalized(history(Value::String(decoded.to_string()))).unwrap();
    assert_eq!(arguments(&value), &decoded);
    assert_eq!(
        arguments(&value)
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["a", "literal", "z"]
    );
    for raw in [
        "null",
        "false",
        "[1,null]",
        "18446744073709551615",
        "[{\"é\":1,\"e\u{301}\":2}]",
        "&amp;",
        "{bad",
        " \r\n  ",
        "e\u{301}",
        "<parameter=x>raw</parameter>",
    ] {
        let value = normalized(history(json!(raw))).unwrap();
        assert_eq!(
            arguments(&value).as_str().unwrap().as_bytes(),
            raw.as_bytes()
        );
    }
    assert!(normalized(history(json!([1, null]))).is_err());
}

#[test]
fn upstream_assistant_framing_cleanup_keeps_mimo_null_and_argument_contract() {
    let raw = "<|channel|>final<|message|>literal<|end|>";
    let body = json!({"model":"mimo-private","messages":[
        {"role":"assistant","content":null,
         "reasoning_content":"<|channel|>analysis<|message|>private thought<|end|>",
         "tool_calls":[{"id":"a","type":"function","function":{
             "name":"f","arguments":json!({"text":raw}).to_string()}}]},
        {"role":"tool","tool_call_id":"a","content":raw},
        {"role":"assistant","content":"<|channel|>final<|message|>Answer.<|end|>"}
    ]});
    let value = normalized(body).unwrap();
    assert_eq!(value.messages[0]["content"], "");
    assert_eq!(value.messages[0]["reasoning_content"], "");
    assert_eq!(
        value.messages[0]["tool_calls"][0]["function"]["arguments"]["text"],
        raw
    );
    assert_eq!(value.messages[1]["content"], raw);
    assert_eq!(value.messages[2]["content"], "Answer.");
}

#[test]
fn native_parameter_values_allow_other_literal_tags_but_not_their_own_closer() {
    for raw in [
        "</function>",
        "</tool_call>",
        "before</function>after &amp;",
    ] {
        let value = normalized(history(Value::String(json!({"x":raw}).to_string()))).unwrap();
        assert_eq!(arguments(&value)["x"], raw);
    }
    for raw in ["before</parameter>after", "</parameter>"] {
        assert!(normalized(history(Value::String(json!({"x":raw}).to_string()))).is_err());
    }
    for raw in ["</function>", "</tool_call>"] {
        assert!(normalized(history(json!(raw))).is_err());
    }
    for key in ["", "bad>key", "bad<key", "bad\nkey", "bad\rkey"] {
        let mut object = Map::new();
        object.insert(key.into(), json!("raw"));
        assert!(normalized(history(Value::String(Value::Object(object).to_string()))).is_err());
    }
    let value = normalized(history(json!("{\"\u{301}x\":\"&amp;\"}"))).unwrap();
    assert_eq!(
        arguments(&value)
            .as_object()
            .unwrap()
            .keys()
            .next()
            .unwrap()
            .as_bytes(),
        "\u{301}x".as_bytes()
    );
}

#[test]
fn native_key_comparison_does_not_rewrite_unicode_key_or_id_bytes() {
    let value = sort_for_swift(json!({"e\u{301}":1,"z":2})).unwrap();
    assert_eq!(
        value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["z", "e\u{301}"]
    );
    let value = normalize_history(vec![
        json!({"role":"assistant","tool_calls":[
            {"id":"é","type":"function","function":{"name":"f","arguments":{}}},
            {"id":"e\u{301}","type":"function","function":{"name":"f","arguments":{}}}]}),
        json!({"role":"tool","tool_call_id":"e\u{301}","content":"D","extra":{"keep":null}}),
        json!({"role":"tool","tool_call_id":"é","content":"C"}),
    ])
    .unwrap();
    assert_eq!(value[1]["content"], "C");
    assert_eq!(value[2]["content"], "D");
    assert_eq!(value[2]["extra"], json!({"keep":null}));
}

#[test]
fn contiguous_parallel_results_reorder_whole_messages_and_reject_loss() {
    let first = json!({"role":"assistant","tool_calls":[
        {"id":"a","type":"function","function":{"name":"f","arguments":{}}},
        {"id":"b","type":"function","function":{"name":"g","arguments":{}}} ]});
    let a = json!({"role":"tool","tool_call_id":"a","name":"f","content":"A &amp;"});
    let b = json!({"role":"tool","tool_call_id":"b","name":"g","content":"B\r\n","extra":[null,1]});
    let output = normalize_history(vec![first.clone(), b.clone(), a.clone()]).unwrap();
    assert_eq!(output[1], a);
    assert_eq!(output[2], b);
    for values in [
        vec![first.clone(), a.clone()],
        vec![first.clone(), a.clone(), a.clone()],
        vec![
            first.clone(),
            a.clone(),
            json!({"role":"tool","tool_call_id":"x","content":"X"}),
        ],
        vec![
            first.clone(),
            a.clone(),
            json!({"role":"user","content":"boundary"}),
            b.clone(),
        ],
        vec![a.clone()],
    ] {
        assert!(normalize_history(values).is_err());
    }
    let mut wrong = b;
    wrong["name"] = json!("wrong");
    assert!(normalize_history(vec![first, a, wrong]).is_err());
}

#[test]
fn every_call_name_id_type_and_argument_shape_is_checked() {
    for (field, bad) in [("id", json!("")), ("type", json!("custom"))] {
        let mut body = history(json!("{}"));
        body["messages"][0]["tool_calls"][0][field] = bad;
        assert!(normalized(body).is_err());
    }
    for name in ["", "bad name", "f>"] {
        let mut body = history(json!("{}"));
        body["messages"][0]["tool_calls"][0]["function"]["name"] = json!(name);
        assert!(normalized(body).is_err());
    }
    let mut body = history(json!("{}"));
    let first = body["messages"][0]["tool_calls"][0].clone();
    body["messages"][0]["tool_calls"]
        .as_array_mut()
        .unwrap()
        .push(first);
    assert!(normalized(body).is_err());
    let mut body = history(json!("{}"));
    body["messages"][0]["role"] = json!("user");
    assert!(normalized(body).is_err());
}

#[test]
fn current_declarations_are_independent_of_historical_calls_and_preserve_schema_nulls() {
    let mut body = history(json!("{}"));
    body["tools"] = json!([{"type":"function","function":{"name":"new_tool",
        "description":"literal &amp;","parameters":{"type":"object","properties":{
            "x":{"type":"null","default":null,"const":null,"enum":[null,"null"]}}}}}]);
    let value = normalized(body.clone()).unwrap();
    let tools = value.tools.unwrap();
    let schema = &tools[0]["function"]["parameters"]["properties"]["x"];
    assert_eq!(schema["enum"], json!([null, "null"]));
    assert!(schema.get("default").unwrap().is_null());
    assert!(schema.get("const").unwrap().is_null());
    assert!(normalized(history(json!("{}"))).is_ok());
    body["tools"][0]["type"] = json!("custom");
    assert!(normalized(body).is_err());
    for declarations in [json!([1]), json!([{"type":"unsupported_hosted_tool"}])] {
        let mut body = history(json!("{}"));
        body["tools"] = declarations;
        assert!(normalized(body).is_err());
    }
}

#[test]
fn strict_boolean_controls_aliases_absence_and_precedence_match_swift() {
    let base = json!({"model":"m","messages":[{"role":"user","content":"hello"}]});
    assert!(
        normalized(base.clone())
            .unwrap()
            .additional_context
            .is_empty()
    );
    for nested in [None, Some(false), Some(true)] {
        for top in [None, Some(false), Some(true)] {
            for alias in [None, Some(false), Some(true)] {
                let mut body = base.clone();
                if let Some(enabled) = nested {
                    body["reasoning"] = json!({"enabled":enabled});
                }
                if let Some(enabled) = top {
                    body["enable_thinking"] = json!(enabled);
                }
                if let Some(enabled) = alias {
                    body["chat_template_kwargs"] = json!({"enable_thinking":enabled});
                }
                let context = normalized(body).unwrap().additional_context;
                assert_eq!(
                    context.get("enable_thinking").and_then(Value::as_bool),
                    nested.or(top).or(alias)
                );
                assert!(!context.contains_key("reasoning_effort"));
            }
        }
    }
    for effort in ["none", " OFF ", "0"] {
        for field in ["reasoning_effort", "reasoning"] {
            let mut body = base.clone();
            body[field] = if field == "reasoning" {
                json!({"effort":effort})
            } else {
                json!(effort)
            };
            assert_eq!(
                normalized(body).unwrap().additional_context["enable_thinking"],
                false
            );
        }
    }
}

#[test]
fn openrouter_thinking_alias_preserves_controls_and_tool_history() {
    for enabled in [false, true] {
        for kwargs in [
            json!({"thinking":enabled}),
            json!({"thinking":enabled,"enable_thinking":enabled}),
            json!({"thinking":!enabled,"enable_thinking":enabled}),
        ] {
            let mut body = history(json!("{}"));
            body["chat_template_kwargs"] = kwargs;
            body["reasoning"] = json!({"enabled":enabled});
            body["max_tokens"] = json!(131072);
            let result = normalized(body).unwrap();
            assert_eq!(result.additional_context["enable_thinking"], enabled);
            assert_eq!(
                result.messages[0]["reasoning_content"],
                "Keep &amp; e\u{301}"
            );
        }
        let result = normalized(json!({"model":"m", "messages":[],
            "chat_template_kwargs":{"thinking":enabled}}))
        .unwrap();
        assert_eq!(result.additional_context["enable_thinking"], enabled);
    }
    for invalid in [json!("false"), json!(0), Value::Null] {
        assert!(
            normalized(json!({"model":"m", "messages":[],
            "chat_template_kwargs":{"thinking":invalid,"enable_thinking":true}}))
            .is_err()
        );
    }
}

#[test]
fn malformed_shadowed_controls_and_unsupported_efforts_are_not_dropped() {
    for bad in [
        json!("false"),
        json!("true"),
        json!(0),
        json!(1),
        Value::Null,
        json!([]),
        json!({}),
    ] {
        for field in ["top", "nested", "kwargs"] {
            let mut body = json!({"model":"m","messages":[]});
            match field {
                "top" => {
                    body["enable_thinking"] = bad.clone();
                    body["reasoning"] = json!({"enabled":true});
                }
                "nested" => body["reasoning"] = json!({"enabled":bad.clone()}),
                _ => body["chat_template_kwargs"] = json!({"enable_thinking":bad.clone()}),
            }
            assert!(normalized(body).is_err(), "{field}/{bad}");
        }
    }
    for effort in [
        "minimal", "low", "medium", "high", "xhigh", "on", "false", "",
    ] {
        assert!(
            normalized(
                json!({"model":"m","messages":[],"reasoning_effort":effort,"enable_thinking":true})
            )
            .is_err()
        );
    }
    for preserve in [json!(false), json!(true), Value::Null] {
        assert!(
            normalized(json!({"model":"m","messages":[],"preserve_thinking":preserve})).is_err()
        );
    }
    assert!(
        normalized(json!({"model":"m","messages":[],"chat_template_kwargs":{"unexpected":true}}))
            .is_err()
    );
    for field in ["exclude", "max_tokens", "unexpected"] {
        let mut body = json!({"model":"m","messages":[],"reasoning":{"enabled":true}});
        body["reasoning"][field] = json!(false);
        assert!(normalized(body).is_err());
    }
}

#[test]
fn old_families_keep_upstream_object_bridge_and_permissive_control_behavior() {
    let mut body = history(json!("{\"a\":[1,null,2],\"x\":null}"));
    body["enable_thinking"] = json!("false");
    for kind in [None, Some("llama"), Some("qwen4_exp")] {
        let value = normalize(body.as_object().unwrap().clone(), kind).unwrap();
        assert_eq!(arguments(&value), &json!({"a":[1,2]}));
        assert!(!value.additional_context.contains_key("enable_thinking"));
    }
    let value = normalize(
        history(json!("[1,null]")).as_object().unwrap().clone(),
        None,
    )
    .unwrap();
    assert_eq!(arguments(&value), &json!("[1,null]"));
    assert!(normalized(body).is_err());
}

#[test]
fn endpoint_text_parts_do_not_silently_drop_unknown_or_audio_content() {
    for kind in ["text", "input_text", "output_text"] {
        let value = normalized(json!({"model":"m","messages":[{"role":"user","content":[{"type":kind,"text":"keep"}]}]})).unwrap();
        assert_eq!(value.messages[0]["content"], "keep");
    }
    for kind in ["unknown", "input_audio", "audio_url"] {
        assert!(normalized(json!({"model":"m","messages":[{"role":"user","content":[{"type":kind,"text":"cannot drop"}]}]})).is_err());
    }
}

#[test]
fn preflight_defers_only_encoded_shape_and_retains_resource_key_numeric_refusals() {
    for raw in ["null", "[1,null]", "{bad"] {
        let body = history(json!(raw));
        assert!(render::validate_request_input_before_contract(&body).is_ok());
        assert!(render::validate_request_input_for_model(&body, Some("mimo_v2")).is_ok());
        assert!(render::validate_request_input_for_model(&body, Some("llama")).is_err());
    }
    let deep = format!("{}0{}", "{\"nested\":".repeat(160), "}".repeat(160));
    let mut encoded_keys = Map::new();
    encoded_keys.insert("é".into(), json!(1));
    encoded_keys.insert("e\u{301}".into(), json!(2));
    for raw in [
        deep,
        "x".repeat((4 << 20) + 1),
        Value::Object(encoded_keys).to_string(),
        "{\"n\":18446744073709551615}".into(),
        "{\"n\":-0.0}".into(),
    ] {
        let body = history(json!(raw));
        assert!(render::validate_request_input_before_contract(&body).is_err());
        assert!(normalized(body).is_err());
    }
    let quoted = serde_json::to_string(&"[".repeat(160)).unwrap();
    assert!(render::validate_request_input_before_contract(&history(json!(quoted))).is_ok());
    let ordinary_text = history(json!(format!("not JSON {}", "[".repeat(160))));
    assert!(render::validate_request_input_before_contract(&ordinary_text).is_ok());
    assert!(render::validate_request_input_for_model(&ordinary_text, Some("llama")).is_ok());
    assert!(serde_json::from_str::<PlanRequest>("{not outer JSON").is_err());
}

#[derive(Deserialize)]
struct Corpus {
    cases: Vec<ReferenceCase>,
    original31_sha256: String,
}
#[derive(Deserialize)]
struct ReferenceCase {
    id: String,
    request_json: String,
    template_input: Value,
    rendered: String,
    rendered_sha256: String,
    token_ids: Vec<u32>,
    decoded: String,
}
fn sha(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn local_read(path: &Path, maximum: u64) -> Vec<u8> {
    let metadata = fs::symlink_metadata(path).expect("required local pinned fixture");
    assert!(metadata.is_file() && !metadata.file_type().is_symlink() && metadata.len() <= maximum);
    let bytes = fs::read(path).unwrap();
    assert!(bytes.len() as u64 <= maximum);
    bytes
}
fn corpus() -> Corpus {
    let path = PathBuf::from(
        std::env::var("MIMO_PROMPT_REFERENCE_VECTORS")
            .expect("set the unchanged additional20 corpus; this gate must not silently skip"),
    );
    let bytes = local_read(&path, 1 << 20);
    assert_eq!(
        sha(&bytes),
        "66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb"
    );
    let value: Corpus = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value.cases.len(), 20);
    assert_eq!(
        value.original31_sha256,
        "c11b2d3a9400bbe935c33f86b1ec6dc0ed91ea6e8b85030d355a4b66d35c2e8e"
    );
    value
}

struct Fixture {
    directory: TempDir,
    contract_id: String,
    metadata: ContractMetadata,
    artifacts: LoadedArtifacts,
}
impl Fixture {
    fn new(model_type: &str, standalone: bool) -> Self {
        let source = PathBuf::from(
            std::env::var("MIMO_PROMPT_ARTIFACT_DIRECTORY")
                .expect("set pinned metadata-only directory; no downloads or model fallback"),
        );
        let pins = [
            (
                "config.json",
                "config",
                "61bea4a0f7a0dd8969f8cae528761e26b697dd12ff63e98804c3f0945492e621",
            ),
            (
                "tokenizer.json",
                "tokenizer",
                "ff15eb925890d6b71b5160de4b846fbd13178438ab463b38ecc953e8cd1dcb3e",
            ),
            (
                "tokenizer_config.json",
                "tokenizer",
                "413a7845f52943ccf4de0e5c838414507d16c44dbf573da9e20bc8902b384d06",
            ),
            (
                "chat_template.jinja",
                "template",
                "853650bee57bf95020373e4c928bd5a4b41b9915adf964a77711d2b49a291887",
            ),
        ];
        let mut files = Vec::new();
        for (name, role, digest) in pins {
            let mut bytes = local_read(&source.join(name), 128 << 20);
            assert_eq!(sha(&bytes), digest, "{name}");
            if name == "config.json" && model_type != "mimo_v2" {
                let mut config: Value = serde_json::from_slice(&bytes).unwrap();
                config["model_type"] = json!(model_type);
                bytes = serde_json::to_vec(&config).unwrap();
            }
            files.push((name.to_owned(), role.to_owned(), bytes));
        }
        let data = |name: &str| {
            files
                .iter()
                .find(|file| file.0 == name)
                .unwrap()
                .2
                .as_slice()
        };
        let tokenizer =
            Arc::new(tokenizers::Tokenizer::from_bytes(data("tokenizer.json")).unwrap());
        let tokenizer_config: Map<String, Value> =
            serde_json::from_slice(data("tokenizer_config.json")).unwrap();
        let model_config = serde_json::from_slice(data("config.json")).unwrap();
        let chat_template = if standalone {
            json!(std::str::from_utf8(data("chat_template.jinja")).unwrap())
        } else {
            tokenizer_config["chat_template"].clone()
        };
        if !standalone {
            files.retain(|file| file.0 != "chat_template.jinja");
        }
        let artifacts = files
            .iter()
            .map(|(name, role, bytes)| PromptArtifact {
                path: name.clone(),
                role: role.clone(),
                size_bytes: bytes.len() as u64,
                sha256: sha(bytes),
            })
            .collect::<Vec<_>>();
        let versions = ContractVersions::default();
        let contract_id = compute_contract_id(&artifacts, &versions).unwrap();
        let metadata = ContractMetadata {
            schema_version: 1,
            prompt_contract_id: contract_id.clone(),
            model_id: "mimo-private".into(),
            model_type: Some(model_type.into()),
            model_aggregate_sha256: "0".repeat(64),
            artifacts,
            versions,
        };
        let directory = TempDir::new().unwrap();
        let root = directory.path().join(&contract_id);
        fs::create_dir(&root).unwrap();
        for (name, _, bytes) in files {
            fs::write(root.join(name), bytes).unwrap();
        }
        fs::write(
            root.join(METADATA_FILE),
            serde_json::to_vec(&metadata).unwrap(),
        )
        .unwrap();
        Self {
            directory,
            contract_id,
            metadata: metadata.clone(),
            artifacts: LoadedArtifacts {
                metadata,
                tokenizer,
                tokenizer_config,
                model_config,
                chat_template,
            },
        }
    }
    fn planner(&self) -> Planner {
        // Resolve the test-owned temporary root; artifact traversal must still
        // reject symlinks in production paths.
        let root = fs::canonicalize(self.directory.path()).unwrap();
        Planner::new(root, 1, 1, 200_000)
    }
    fn request(&self, body: Value) -> PlanRequest {
        PlanRequest {
            prompt_contract_id: self.contract_id.clone(),
            scope_id: "mimo-source-parity".into(),
            endpoint: Endpoint::ChatCompletions,
            body,
        }
    }
}

#[tokio::test]
async fn actual_normalize_render_tokenizer_and_planner_match_all20_for_both_source_copies() {
    let corpus = corpus();
    for standalone in [true, false] {
        let fixture = Fixture::new("mimo_v2", standalone);
        let planner = fixture.planner();
        for case in &corpus.cases {
            let body: Value = serde_json::from_str(&case.request_json).unwrap();
            let value = normalized(body.clone()).unwrap();
            assert_eq!(
                Value::Array(value.messages.clone()),
                case.template_input["messages"],
                "{}",
                case.id
            );
            assert_eq!(
                value
                    .tools
                    .as_ref()
                    .map(|tools| Value::Array(tools.clone())),
                case.template_input.get("tools").cloned(),
                "{}",
                case.id
            );
            assert_eq!(
                value.additional_context.get("enable_thinking"),
                case.template_input.get("enable_thinking"),
                "{}",
                case.id
            );
            let rendered = render::render(&fixture.artifacts, &value).unwrap();
            assert_eq!(rendered.as_bytes(), case.rendered.as_bytes(), "{}", case.id);
            assert_eq!(
                sha(rendered.as_bytes()),
                case.rendered_sha256,
                "{}",
                case.id
            );
            let encoding = fixture.artifacts.tokenizer.encode(rendered, false).unwrap();
            assert_eq!(encoding.get_ids(), case.token_ids.as_slice(), "{}", case.id);
            let decoded = fixture
                .artifacts
                .tokenizer
                .decode(encoding.get_ids(), false)
                .unwrap();
            assert_eq!(decoded.as_bytes(), case.decoded.as_bytes(), "{}", case.id);
            let (plan, ids, input, provider_body) = planner
                .fixture_plan(fixture.request(body.clone()))
                .await
                .unwrap();
            assert_eq!(ids, case.token_ids, "{}", case.id);
            assert_eq!(input, value.fixture_body(), "{}", case.id);
            assert_eq!(provider_body, body);
            assert_eq!(plan.prompt_token_count as usize, case.token_ids.len());
        }
        assert_eq!(planner.status().metrics.contract_loads.cold, 1);
        assert_eq!(planner.status().metrics.contract_loads.warm, 19);
    }
}

#[tokio::test]
async fn planner_preserves_cold_resource_key_numeric_refusals_before_lookup() {
    let fixture = Fixture::new("mimo_v2", true);
    let planner = fixture.planner();
    let deep = format!("{}0{}", "{\"n\":".repeat(160), "}".repeat(160));
    for raw in [
        deep,
        "x".repeat((4 << 20) + 1),
        "{\"é\":1,\"e\\u0301\":2}".into(),
        "{\"n\":-0.0}".into(),
    ] {
        assert!(matches!(
            planner.plan(fixture.request(history(json!(raw)))).await,
            Err(PlanError::Render(RenderError::UnsupportedInput))
        ));
    }
    let mut keys = history(json!("{}"));
    keys["extra"] = json!({"é":1,"e\u{301}":2});
    assert!(matches!(
        planner.plan(fixture.request(keys)).await,
        Err(PlanError::Render(RenderError::UnsupportedInput))
    ));
    assert_eq!(planner.status().metrics.contract_loads.cold, 0);
}

#[tokio::test]
async fn legacy_deferred_shape_rejects_after_one_trusted_lookup_despite_request_spoof() {
    let fixture = Fixture::new("llama", true);
    let planner = fixture.planner();
    for raw in ["null", "[1,null]", "{bad"] {
        let mut body = history(json!(raw));
        body["model"] = json!("XiaomiMiMo/MiMo-V2.6-Flash-RL");
        body["model_type"] = json!("mimo_v2");
        assert!(matches!(
            planner.plan(fixture.request(body)).await,
            Err(PlanError::Render(RenderError::UnsupportedInput))
        ));
    }
    assert_eq!(planner.status().metrics.contract_loads.cold, 1);
    assert_eq!(planner.status().metrics.contract_loads.warm, 2);
    assert_eq!(planner.status().metrics.plans.succeeded, 0);
}

#[tokio::test]
async fn missing_mismatched_and_url_contracts_do_not_provision_or_select_mimo() {
    let fixture = Fixture::new("mimo_v2", true);
    for id in [
        "f".repeat(64),
        "https://untrusted.invalid/mimo".into(),
        "../mimo".into(),
    ] {
        let planner = fixture.planner();
        let mut request = fixture.request(history(json!("null")));
        request.prompt_contract_id = id;
        assert!(matches!(
            planner.plan(request).await,
            Err(PlanError::Contract)
        ));
        assert_eq!(planner.status().metrics.plans.succeeded, 0);
    }
    assert_eq!(fs::read_dir(fixture.directory.path()).unwrap().count(), 1);
    let mut metadata = fixture.metadata.clone();
    metadata.model_type = Some("llama".into());
    fs::write(
        fixture
            .directory
            .path()
            .join(&fixture.contract_id)
            .join(METADATA_FILE),
        serde_json::to_vec(&metadata).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        fixture
            .planner()
            .plan(fixture.request(history(json!("null"))))
            .await,
        Err(PlanError::Contract)
    ));
}

#[tokio::test]
async fn pre_dispatch_cancel_and_not_ready_never_start_contract_work() {
    let fixture = Fixture::new("mimo_v2", true);
    let planner = fixture.planner();
    let request = fixture.request(history(json!("null")));
    drop(planner.fixture_plan(request.clone())); // Never-polled future: real cancellation boundary.
    assert_eq!(planner.status().metrics.contract_loads.cold, 0);
    assert_eq!(planner.status().metrics.plans.started, 0);
    planner.mark_starting();
    assert!(matches!(
        planner.plan(request).await,
        Err(PlanError::NotReady)
    ));
    assert_eq!(planner.status().metrics.contract_loads.cold, 0);
    // Existing spawn_blocking work is not claimed preemptible after dispatch.
}

#[tokio::test]
async fn planner_rejects_wrong_control_and_history_types_and_lowers_responses_none() {
    let fixture = Fixture::new("mimo_v2", true);
    let planner = fixture.planner();
    for bad in [json!("false"), json!(0), json!(1), Value::Null] {
        let mut body = history(json!("{}"));
        body["enable_thinking"] = bad;
        assert!(matches!(
            planner.plan(fixture.request(body)).await,
            Err(PlanError::Normalize)
        ));
    }
    let mut missing = history(json!("{}"));
    missing["messages"][1]["tool_call_id"] = json!("unknown");
    assert!(matches!(
        planner.plan(fixture.request(missing)).await,
        Err(PlanError::Normalize)
    ));
    assert!(matches!(
        planner
            .plan(fixture.request(history(json!([1, null]))))
            .await,
        Err(PlanError::Normalize)
    ));
    let mut request = fixture
        .request(json!({"model":"mimo-private","input":"hello","reasoning":{"effort":"none"}}));
    request.endpoint = Endpoint::Responses;
    let (_, ids, input, _) = planner.fixture_plan(request).await.unwrap();
    assert_eq!(input["additional_context"]["enable_thinking"], false);
    let expected = "<|im_start|>user\nhello<|im_end|><|im_start|>assistant\n<think></think>";
    assert_eq!(
        ids,
        fixture
            .artifacts
            .tokenizer
            .encode(expected, false)
            .unwrap()
            .get_ids()
    );
}

#[test]
fn real_renderer_keeps_literal_nonparameter_closers_inside_parameter_values() {
    let fixture = Fixture::new("mimo_v2", true);
    for raw in ["</function>", "</tool_call>"] {
        let value = normalized(history(Value::String(json!({"x":raw}).to_string()))).unwrap();
        let rendered = render::render(&fixture.artifacts, &value).unwrap();
        assert!(rendered.contains(&format!("<parameter=x>{raw}</parameter>")));
    }
}
