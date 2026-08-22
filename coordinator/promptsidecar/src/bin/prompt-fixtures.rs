use anyhow::{Context, Result, bail};
use clap::Parser;
use promptsidecar::api::{Endpoint, PlanRequest, PlanResponse};
use promptsidecar::contract::{
    ContractVersions, PromptArtifact, compute_contract_id, is_prompt_role,
};
use promptsidecar::planner::{PlanError, Planner};
use promptsidecar::render::RenderError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(about = "Generate prompt-contract vectors from immutable local artifacts")]
struct Arguments {
    #[arg(long)]
    manifest: Vec<PathBuf>,
    #[arg(long)]
    manifest_directory: Option<PathBuf>,
    #[arg(long)]
    artifact_root: PathBuf,
    #[arg(long)]
    cases: PathBuf,
    #[arg(long)]
    output: PathBuf,
}

#[derive(Deserialize)]
struct CatalogManifest {
    model_id: String,
    #[serde(default)]
    model_type: Option<String>,
    files: Vec<PromptArtifact>,
}

#[derive(Deserialize)]
struct CaseCorpus {
    schema_version: u32,
    cases: Vec<FixtureCase>,
}

#[derive(Clone, Deserialize)]
struct FixtureCase {
    id: String,
    endpoint: Endpoint,
    scope_id: String,
    body: Value,
    #[serde(default)]
    repeat: Option<RepeatRule>,
}

#[derive(Clone, Deserialize)]
struct RepeatRule {
    text: String,
    #[serde(default)]
    exact_tokens: Option<usize>,
    #[serde(default)]
    minimum_tokens: Option<usize>,
    max_repetitions: usize,
}

#[derive(Serialize)]
struct GeneratedCorpus {
    schema_version: u32,
    models: Vec<GeneratedModel>,
}

#[derive(Serialize)]
struct GeneratedModel {
    model_id: String,
    model_type: Option<String>,
    prompt_contract_id: String,
    cache_routing_eligible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    ineligibility_reason: Option<&'static str>,
    cases: Vec<GeneratedCase>,
}

#[derive(Serialize)]
struct GeneratedCase {
    id: String,
    endpoint: Endpoint,
    scope_id: String,
    request_body: Value,
    provider_body: Value,
    template_input: Value,
    plan: PlanResponse,
    token_ids: Vec<u32>,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let manifest_paths = manifest_paths(&arguments)?;
    let mut manifests = manifest_paths
        .iter()
        .map(read_json::<CatalogManifest>)
        .collect::<Result<Vec<_>>>()?;
    manifests.sort_by(|a, b| a.model_id.cmp(&b.model_id));
    let mut corpus = read_json::<CaseCorpus>(&arguments.cases)?;
    if corpus.schema_version != 1 {
        bail!("unsupported case-corpus schema");
    }
    corpus.cases.sort_by(|a, b| a.id.cmp(&b.id));
    require_case_ids(&corpus.cases)?;
    require_model_manifests(&manifests)?;

    let planner = Planner::new(arguments.artifact_root, 1, manifests.len(), 1_000_000);
    let mut models = Vec::with_capacity(manifests.len());
    for manifest in manifests {
        let artifacts = manifest
            .files
            .iter()
            .filter(|artifact| is_prompt_role(&artifact.role))
            .cloned()
            .collect::<Vec<_>>();
        let contract_id = compute_contract_id(&artifacts, &ContractVersions::default())
            .with_context(|| format!("invalid contract for model {}", manifest.model_id))?;
        let mut generated_cases = Vec::with_capacity(corpus.cases.len());
        let mut ineligibility_reason = None;
        for fixture in &corpus.cases {
            let generated =
                generate_case(&planner, fixture, &manifest.model_id, &contract_id).await;
            let (request_body, provider_body, template_input, plan, token_ids) = match generated {
                Ok(generated) => generated,
                Err(error) if is_dynamic_time(&error) => {
                    ineligibility_reason = Some("dynamic_time");
                    generated_cases.clear();
                    break;
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!(
                            "fixture {} failed for model {}; production prompt contract is not parity-ready",
                            fixture.id, manifest.model_id
                        )
                    });
                }
            };
            generated_cases.push(GeneratedCase {
                id: fixture.id.clone(),
                endpoint: fixture.endpoint,
                scope_id: fixture.scope_id.clone(),
                request_body,
                provider_body,
                template_input,
                plan,
                token_ids,
            });
        }
        models.push(GeneratedModel {
            model_id: manifest.model_id,
            model_type: manifest.model_type,
            prompt_contract_id: contract_id,
            cache_routing_eligible: ineligibility_reason.is_none(),
            ineligibility_reason,
            cases: generated_cases,
        });
    }
    let encoded = serde_json::to_vec_pretty(&GeneratedCorpus {
        schema_version: 1,
        models,
    })?;
    let parent = arguments
        .output
        .parent()
        .context("output path has no parent")?;
    fs::create_dir_all(parent)?;
    let temporary = arguments.output.with_extension("json.tmp");
    fs::write(&temporary, encoded)?;
    fs::rename(temporary, arguments.output)?;
    Ok(())
}

fn is_dynamic_time(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<PlanError>()
        .is_some_and(|error| matches!(error, PlanError::Render(RenderError::DynamicTime)))
}

fn require_model_manifests(manifests: &[CatalogManifest]) -> Result<()> {
    if manifests.is_empty() {
        bail!("production catalog supplied no model manifests");
    }
    let provided = manifests
        .iter()
        .map(|manifest| manifest.model_id.as_str())
        .collect::<std::collections::HashSet<_>>();
    if provided.len() != manifests.len() {
        bail!("duplicate model manifests are not allowed");
    }
    Ok(())
}

async fn generate_case(
    planner: &Planner,
    fixture: &FixtureCase,
    model_id: &str,
    contract_id: &str,
) -> Result<(Value, Value, Value, PlanResponse, Vec<u32>)> {
    let mut body = replace_model_id(fixture.body.clone(), model_id);
    if fixture.repeat.is_none() {
        let (plan, token_ids, template_input, provider_body) =
            plan(planner, fixture, contract_id, body.clone()).await?;
        return Ok((body, provider_body, template_input, plan, token_ids));
    }
    let repeat = fixture.repeat.as_ref().expect("checked");
    for repetitions in 0..=repeat.max_repetitions {
        let suffix = repeat.text.repeat(repetitions);
        body = replace_repeat(replace_model_id(fixture.body.clone(), model_id), &suffix);
        let (generated, token_ids, template_input, provider_body) =
            plan(planner, fixture, contract_id, body.clone()).await?;
        let count = token_ids.len();
        if repeat.exact_tokens == Some(count)
            || repeat
                .minimum_tokens
                .is_some_and(|minimum| count >= minimum)
        {
            return Ok((body, provider_body, template_input, generated, token_ids));
        }
        if repeat.exact_tokens.is_some_and(|target| count > target) {
            break;
        }
    }
    bail!("repeat rule could not satisfy token-count constraint")
}

async fn plan(
    planner: &Planner,
    fixture: &FixtureCase,
    contract_id: &str,
    body: Value,
) -> Result<(PlanResponse, Vec<u32>, Value, Value)> {
    planner
        .fixture_plan(PlanRequest {
            prompt_contract_id: contract_id.to_owned(),
            scope_id: fixture.scope_id.clone(),
            endpoint: fixture.endpoint,
            body,
        })
        .await
        .map_err(Into::into)
}

fn replace_model_id(value: Value, model_id: &str) -> Value {
    replace_string(value, "{{MODEL_ID}}", model_id)
}

fn replace_repeat(value: Value, repeated: &str) -> Value {
    replace_string(value, "{{REPEAT}}", repeated)
}

fn replace_string(value: Value, needle: &str, replacement: &str) -> Value {
    match value {
        Value::String(value) => Value::String(value.replace(needle, replacement)),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| replace_string(value, needle, replacement))
                .collect(),
        ),
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, replace_string(value, needle, replacement)))
                .collect(),
        ),
        value => value,
    }
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &PathBuf) -> Result<T> {
    serde_json::from_slice(&fs::read(path).with_context(|| format!("read {}", path.display()))?)
        .with_context(|| format!("parse {}", path.display()))
}

fn manifest_paths(arguments: &Arguments) -> Result<Vec<PathBuf>> {
    let mut paths = arguments.manifest.clone();
    if let Some(directory) = &arguments.manifest_directory {
        for entry in fs::read_dir(directory)
            .with_context(|| format!("read manifest directory {}", directory.display()))?
        {
            let path = entry?.path();
            if path
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                paths.push(path);
            }
        }
    }
    paths.sort();
    if paths.is_empty() {
        bail!("at least one production model manifest is required");
    }
    Ok(paths)
}

fn require_case_ids(cases: &[FixtureCase]) -> Result<()> {
    const REQUIRED: [&str; 14] = [
        "tools",
        "nulls",
        "harmony",
        "gemma",
        "gemma_tool_turn",
        "reasoning_effort",
        "unicode",
        "endpoint_chat_completions",
        "endpoint_completions",
        "endpoint_responses",
        "endpoint_messages",
        "endpoint_messages_tool_turn",
        "exact_block_multiple",
        "long_prompt",
    ];
    for required in REQUIRED {
        if !cases.iter().any(|fixture| fixture.id == required) {
            bail!("required case {required} is missing");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_model_inventory_is_mandatory() {
        assert!(require_model_manifests(&[]).is_err());
    }

    #[test]
    fn tool_turn_case_names_are_mandatory() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/prompt-contract/v1/corpus.json");
        let corpus: CaseCorpus = read_json(&path).unwrap();
        assert_eq!(corpus.schema_version, 1);
        for required in ["gemma_tool_turn", "endpoint_messages_tool_turn"] {
            let mut cases = corpus.cases.clone();
            cases
                .iter_mut()
                .find(|fixture| fixture.id == required)
                .unwrap()
                .id = format!("{required}_substitute");
            assert_eq!(cases.len(), corpus.cases.len());
            assert!(
                require_case_ids(&cases).is_err(),
                "replacement preserved required case {required}"
            );
        }
    }

    #[test]
    fn dynamic_time_is_an_explicit_cold_only_capability() {
        let error = anyhow::Error::new(PlanError::Render(RenderError::DynamicTime));
        assert!(is_dynamic_time(&error));
        assert!(!is_dynamic_time(&anyhow::Error::new(PlanError::Tokenize)));
    }
}
