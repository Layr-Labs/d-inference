//! Mirror MLXOpenAIService's preparation before ToolChoicePromptPolicy and
//! tokenization. Keep generation instructions in the planner only: the provider
//! service inserts them itself, so rewriting the provider body would double them.

use crate::normalize::NormalizeError;
use serde_json::{Map, Value, json};

pub(crate) fn prepare(
    body: &Map<String, Value>,
    messages: &mut Vec<Value>,
) -> Result<(), NormalizeError> {
    let Some(format) = body.get("response_format").filter(|v| !v.is_null()) else {
        return Ok(());
    };
    let kind = format.get("type").and_then(Value::as_str);
    let instruction = match kind {
        Some("text") => return Ok(()),
        Some("json_object") => concat!(
            "You must respond with a single valid JSON object. Do not include markdown, code fences, comments, ",
            "explanations, or extra text. The first non-whitespace character must be \"{\" and the final ",
            "non-whitespace character must be \"}\"."
        ).to_owned(),
        Some("json_schema") => {
            let schema = format.get("json_schema").and_then(Value::as_object)
                .ok_or(NormalizeError::InvalidMessages)?;
            let value = schema.get("schema").ok_or(NormalizeError::InvalidMessages)?;
            let name = optional_string(schema, "name")?.map(|v| format!(" Schema name: {v}."))
                .unwrap_or_default();
            let description = optional_string(schema, "description")?.map(|v| format!(" Description: {v}"))
                .unwrap_or_default();
            let strict = match schema.get("strict") {
                None | Some(Value::Null) | Some(Value::Bool(false)) => "",
                Some(Value::Bool(true)) => " The output must strictly conform to the schema.",
                _ => return Err(NormalizeError::InvalidMessages),
            };
            let encoded = crate::render::openai_json(value).map_err(|_| NormalizeError::InvalidMessages)?;
            format!(concat!(
                "You must respond with a single valid JSON value that conforms to the supplied JSON Schema. Do not ",
                "include markdown, code fences, comments, explanations, or extra text.{}{}{}\nJSON Schema:\n{}"
            ), name, description, strict, encoded)
        }
        _ => return Err(NormalizeError::InvalidMessages),
    };
    let position = messages
        .iter()
        .position(|message| message.get("role").and_then(Value::as_str) != Some("system"))
        .unwrap_or(messages.len());
    messages.insert(position, json!({"role": "system", "content": instruction}));
    Ok(())
}

fn optional_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a str>, NormalizeError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        _ => Err(NormalizeError::InvalidMessages),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preparation_occurs_after_initial_system_messages_and_does_not_mutate_body() {
        let body = json!({"response_format":{"type":"json_object"}})
            .as_object()
            .unwrap()
            .clone();
        let mut messages = vec![
            json!({"role":"system","content":"first"}),
            json!({"role":"user","content":"question"}),
        ];
        prepare(&body, &mut messages).unwrap();
        assert_eq!(messages[0]["content"], "first");
        assert_eq!(messages[1]["role"], "system");
        assert!(
            messages[1]["content"]
                .as_str()
                .unwrap()
                .starts_with("You must respond with a single valid JSON object.")
        );
        assert_eq!(messages[2]["role"], "user");
        assert!(!body.contains_key("messages"));
    }

    #[test]
    fn schema_uses_typed_foundation_encoding_and_exact_optional_text() {
        let body = json!({"response_format":{"type":"json_schema","json_schema":{
            "name":"example","description":"public","strict":true,
            "schema":{"z":1.0,"a":"café / 🐈","nil":null,"minimum":0.00001}
        }}})
        .as_object()
        .unwrap()
        .clone();
        let mut messages = vec![];
        prepare(&body, &mut messages).unwrap();
        let content = messages[0]["content"].as_str().unwrap();
        assert!(content.contains(" Schema name: example. Description: public The output must strictly conform to the schema.\nJSON Schema:\n"));
        assert!(content.ends_with("{\"a\":\"café / 🐈\",\"minimum\":1e-05,\"nil\":null,\"z\":1}"));
    }

    #[test]
    fn malformed_formats_fail_cold_and_text_is_unchanged() {
        for format in [
            json!({"type":"bogus"}),
            json!({"type":"json_schema"}),
            json!({"type":"json_schema","json_schema":{"schema":{},"name":5}}),
        ] {
            assert!(
                prepare(
                    &json!({"response_format":format})
                        .as_object()
                        .unwrap()
                        .clone(),
                    &mut vec![]
                )
                .is_err()
            );
        }
        for format in [json!(null), json!({"type":"text"})] {
            let mut messages = vec![json!({"role":"user","content":"same"})];
            let original = messages.clone();
            prepare(
                &json!({"response_format":format})
                    .as_object()
                    .unwrap()
                    .clone(),
                &mut messages,
            )
            .unwrap();
            assert_eq!(messages, original);
        }
    }
}
