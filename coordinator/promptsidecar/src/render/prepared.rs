//! Immutable template programs live exactly as long as their verified contract.
//! At most two selectable variants are retained; request state lives in render.
use super::{RenderError, json, nemotron, raise_exception};
use crate::artifacts::LoadedArtifacts;
use crate::normalize::NormalizedRequest;
use minijinja::Environment;
use serde_json::Value;
use std::sync::OnceLock;

const RENDER_FUEL: u64 = 10_000_000;
// Keep retention below the existing artifact admission envelope. Large trusted
// templates still render with the original ephemeral compilation and bounds.
const MAX_RETAINED_TEMPLATE_BYTES: usize = 64 << 10;

#[derive(Default)]
pub(crate) struct PreparedTemplates {
    plain: OnceLock<Result<Environment<'static>, RenderError>>,
    tools: OnceLock<Result<Environment<'static>, RenderError>>,
}

impl PreparedTemplates {
    pub(crate) fn render(
        &self,
        artifacts: &LoadedArtifacts,
        request: &NormalizedRequest,
    ) -> Result<String, RenderError> {
        let has_tools = request
            .tools
            .as_ref()
            .is_some_and(|tools| !tools.is_empty());
        let source = super::select_template(&artifacts.chat_template, has_tools)?;
        // Eligibility remains request-specific and precedes cached syntax
        // errors, preserving missing/unsupported-date cold-path classification.
        super::validate_template_source(source, request.prompt_date.as_deref())?;
        if source.len() > MAX_RETAINED_TEMPLATE_BYTES {
            let environment = compile_template(artifacts, source)?;
            return super::render_with_environment(&environment, artifacts, request);
        }
        let slot = if has_tools { &self.tools } else { &self.plain };
        let environment = slot.get_or_init(|| compile_template(artifacts, source));
        let environment = environment.as_ref().map_err(Clone::clone)?;
        super::render_with_environment(environment, artifacts, request)
    }
}

pub(super) fn compile_template(
    artifacts: &LoadedArtifacts,
    source: &str,
) -> Result<Environment<'static>, RenderError> {
    let mut environment = Environment::new();
    environment.set_lstrip_blocks(true);
    environment.set_trim_blocks(true);
    environment.set_fuel(Some(RENDER_FUEL));
    environment.set_unknown_method_callback(minijinja_contrib::pycompat::unknown_method_callback);
    minijinja_contrib::add_to_environment(&mut environment);
    environment.add_filter("tojson", json::tojson);
    if artifacts
        .model_config
        .get("model_type")
        .and_then(Value::as_str)
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("nemotron_h"))
    {
        environment.add_filter("string", nemotron::string);
        environment.add_filter("tojson", nemotron::tojson);
    }
    environment.add_function("raise_exception", raise_exception);
    environment
        .add_template_owned("chat", source.to_owned())
        .map_err(|_| RenderError::Template)?;
    Ok(environment)
}

#[cfg(test)]
mod tests;
