mod input;
mod json;

pub(crate) use input::validate_request_input;

use crate::artifacts::LoadedArtifacts;
use crate::normalize::NormalizedRequest;
use minijinja::{Environment, Error, ErrorKind, Value as JinjaValue};
use serde_json::{Map, Value};
use std::io::{self, Write};
use thiserror::Error;

const MAX_RENDERED_BYTES: usize = 16 << 20;
const RENDER_FUEL: u64 = 10_000_000;
const SPECIAL_TOKEN_ATTRIBUTES: [&str; 8] = [
    "bos_token",
    "eos_token",
    "unk_token",
    "sep_token",
    "pad_token",
    "cls_token",
    "mask_token",
    "additional_special_tokens",
];

#[derive(Debug, Error)]
pub enum RenderError {
    #[error("prompt contract has no selectable chat template")]
    MissingTemplate,
    #[error("chat template render failed")]
    Template,
    #[error("chat template output exceeded its bound")]
    OutputTooLarge,
    #[error("chat template has no supported request-owned date")]
    DynamicTime,
    #[error("request input cannot be rendered identically across runtimes")]
    UnsupportedInput,
}

pub fn render(
    artifacts: &LoadedArtifacts,
    request: &NormalizedRequest,
) -> Result<String, RenderError> {
    let template_source = select_template(
        &artifacts.chat_template,
        request
            .tools
            .as_ref()
            .is_some_and(|tools| !tools.is_empty()),
    )?;
    validate_template_source(template_source, request.prompt_date.as_deref())?;

    let mut context = Map::new();
    context.insert("messages".into(), Value::Array(request.messages.clone()));
    context.insert("add_generation_prompt".into(), Value::Bool(true));
    if let Some(tools) = &request.tools {
        context.insert("tools".into(), Value::Array(tools.clone()));
    }
    for (key, value) in &request.additional_context {
        context.insert(key.clone(), value.clone());
    }
    for key in SPECIAL_TOKEN_ATTRIBUTES {
        if let Some(value) = artifacts.tokenizer_config.get(key)
            && let Some(value) = special_token_value(value)
        {
            context.insert(key.into(), value);
        }
    }

    let mut environment = Environment::new();
    environment.set_lstrip_blocks(true);
    environment.set_trim_blocks(true);
    environment.set_fuel(Some(RENDER_FUEL));
    environment.set_unknown_method_callback(minijinja_contrib::pycompat::unknown_method_callback);
    minijinja_contrib::add_to_environment(&mut environment);
    environment.add_filter("tojson", json::tojson);
    environment.add_function("raise_exception", raise_exception);
    let date = request.prompt_date.clone();
    environment.add_function(
        "strftime_now",
        move |format: String| -> Result<String, Error> {
            if format != "%Y-%m-%d" {
                return Err(Error::new(
                    ErrorKind::InvalidOperation,
                    "unsupported prompt date format",
                ));
            }
            date.clone()
                .ok_or_else(|| Error::new(ErrorKind::InvalidOperation, "missing prompt date"))
        },
    );
    environment
        .add_template("chat", template_source)
        .map_err(|_| RenderError::Template)?;
    let template = environment
        .get_template("chat")
        .map_err(|_| RenderError::Template)?;
    let mut output = BoundedWriter::new(MAX_RENDERED_BYTES);
    render_bounded(
        &template,
        JinjaValue::from_serialize(Value::Object(context)),
        &mut output,
    )?;
    output.into_string()
}

fn validate_template_source(template_source: &str, date: Option<&str>) -> Result<(), RenderError> {
    if !crate::request_date::supports_template(template_source)
        || (template_source.contains("strftime_now")
            && !date.is_some_and(crate::request_date::valid_date))
    {
        return Err(RenderError::DynamicTime);
    }
    Ok(())
}

fn select_template(template: &Value, has_tools: bool) -> Result<&str, RenderError> {
    if let Some(template) = template.as_str() {
        return Ok(template);
    }
    let entries = template.as_array().ok_or(RenderError::MissingTemplate)?;
    let mut default = None;
    let mut tool_use = None;
    for entry in entries {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        let Some(name) = entry.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(template) = entry.get("template").and_then(Value::as_str) else {
            continue;
        };
        match name {
            "default" => default = Some(template),
            "tool_use" => tool_use = Some(template),
            _ => {}
        }
    }
    if has_tools {
        tool_use.or(default).ok_or(RenderError::MissingTemplate)
    } else {
        default.ok_or(RenderError::MissingTemplate)
    }
}

fn special_token_value(value: &Value) -> Option<Value> {
    match value {
        Value::String(_) | Value::Array(_) => Some(value.clone()),
        Value::Object(object) => object
            .get("content")
            .and_then(Value::as_str)
            .map(|content| Value::String(content.to_owned())),
        _ => None,
    }
}

fn raise_exception(message: Option<String>) -> Result<String, Error> {
    Err(Error::new(
        ErrorKind::InvalidOperation,
        message.unwrap_or_else(|| "template raised an exception".into()),
    ))
}

#[allow(deprecated)]
fn render_bounded(
    template: &minijinja::Template<'_, '_>,
    context: JinjaValue,
    output: &mut BoundedWriter,
) -> Result<(), RenderError> {
    template
        .render_to_write(context, &mut *output)
        .map(|_| ())
        .map_err(|_| {
            if output.exceeded {
                RenderError::OutputTooLarge
            } else {
                RenderError::Template
            }
        })
}

struct BoundedWriter {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}

impl BoundedWriter {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
            exceeded: false,
        }
    }

    fn into_string(self) -> Result<String, RenderError> {
        String::from_utf8(self.bytes).map_err(|_| RenderError::Template)
    }
}

impl Write for BoundedWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        if buffer.len() > remaining {
            self.exceeded = true;
            return Err(io::Error::other("render output bound exceeded"));
        }
        let required = self.bytes.len() + buffer.len();
        if required > self.bytes.capacity() {
            // Vec's default geometric growth can reserve past the byte bound.
            // Clamp capacity as well as length, including a JSON filter's
            // temporary reduction while its sorted key vectors are alive.
            let target = required.max(self.bytes.capacity().saturating_mul(2).min(self.limit));
            self.bytes
                .try_reserve_exact(target - self.bytes.len())
                .map_err(io::Error::other)?;
        }
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date_artifacts() -> LoadedArtifacts {
        use crate::contract::{ContractMetadata, ContractVersions};
        LoadedArtifacts {
            metadata: ContractMetadata {
                schema_version: 1,
                prompt_contract_id: String::new(),
                model_id: "gpt-oss-20b".into(),
                model_type: Some("gpt_oss".into()),
                model_aggregate_sha256: String::new(),
                artifacts: vec![],
                versions: ContractVersions::default(),
            },
            tokenizer: tokenizers::Tokenizer::new(tokenizers::models::bpe::BPE::default()).into(),
            tokenizer_config: Map::new(),
            model_config: Map::new(),
            chat_template: Value::String(r#"Current date: {{ strftime_now("%Y-%m-%d") }}"#.into()),
        }
    }

    #[test]
    fn renders_from_request_date_and_refuses_unowned_clock() {
        let artifacts = date_artifacts();
        let mut body = serde_json::json!({
            "model":"gpt-oss-20b", "messages":[{"role":"user","content":"hello"}],
            "_darkbloom_prompt_date":"2028-02-29"
        })
        .as_object()
        .unwrap()
        .clone();
        let request = crate::normalize::normalize(body.clone(), Some("gpt_oss")).unwrap();
        assert_eq!(
            render(&artifacts, &request).unwrap(),
            "Current date: 2028-02-29"
        );
        body.insert(
            "_darkbloom_prompt_date".into(),
            Value::String("2028-03-01".into()),
        );
        let next = crate::normalize::normalize(body.clone(), Some("gpt_oss")).unwrap();
        assert_eq!(
            render(&artifacts, &next).unwrap(),
            "Current date: 2028-03-01"
        );
        assert_eq!(
            render(&artifacts, &request).unwrap(),
            "Current date: 2028-02-29"
        );
        for date in [
            Value::Null,
            Value::String("2026-02-29".into()),
            Value::Bool(true),
        ] {
            body.insert("_darkbloom_prompt_date".into(), date);
            let request = crate::normalize::normalize(body.clone(), Some("gpt_oss")).unwrap();
            assert!(matches!(
                render(&artifacts, &request),
                Err(RenderError::DynamicTime)
            ));
        }
    }

    #[test]
    fn shared_request_date_whitespace_vectors() {
        let corpus: Value = serde_json::from_str(include_str!(
            "../../../fixtures/prompt-contract/v1/request_date_vectors.json"
        ))
        .unwrap();
        let mut artifacts = date_artifacts();
        let request = crate::normalize::normalize(
            serde_json::json!({
                "model":"gpt-oss-20b", "messages":[{"role":"user","content":"hello"}],
                "_darkbloom_prompt_date": corpus["date"]
            })
            .as_object()
            .unwrap()
            .clone(),
            Some("gpt_oss"),
        )
        .unwrap();
        let cases = corpus["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for fixture in cases {
            artifacts.chat_template = fixture["template"].clone();
            assert_eq!(
                render(&artifacts, &request).unwrap(),
                fixture["expected"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn rejects_provider_local_time() {
        assert!(matches!(
            validate_template_source(r#"{{ strftime_now("%Y-%m-%d") }}"#, None),
            Err(RenderError::DynamicTime)
        ));
        assert!(
            validate_template_source(r#"{{ strftime_now("%Y-%m-%d") }}"#, Some("2028-02-29"))
                .is_ok()
        );
        assert!(
            validate_template_source(r#"{{ strftime_now("%Y-%m-%d") }}"#, Some("2026-02-29"))
                .is_err()
        );
    }
}
