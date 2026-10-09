use super::*;
use crate::contract::{ContractMetadata, ContractVersions};
use serde_json::{Map, json};
use std::sync::{Arc, Barrier};

fn artifacts(template: Value) -> LoadedArtifacts {
    LoadedArtifacts {
        metadata: ContractMetadata {
            schema_version: 1,
            prompt_contract_id: String::new(),
            model_id: "test".into(),
            model_type: None,
            model_aggregate_sha256: String::new(),
            artifacts: vec![],
            versions: ContractVersions::default(),
        },
        tokenizer: tokenizers::Tokenizer::new(tokenizers::models::bpe::BPE::default()).into(),
        tokenizer_config: Map::new(),
        model_config: Map::new(),
        chat_template: template,
    }
}

fn request(content: &str, date: &str, tools: bool) -> NormalizedRequest {
    let mut body = json!({"model":"test", "messages":[{"role":"user","content":content}],
        "_darkbloom_prompt_date":date});
    if tools {
        body["tools"] =
            json!([{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]);
    }
    crate::normalize::normalize(body.as_object().unwrap().clone(), None).unwrap()
}

#[test]
fn concurrent_compilation_preserves_each_render_date_context_and_fuel() {
    let artifacts = Arc::new(artifacts(json!(
        "{{ strftime_now('%Y-%m-%d') }}|{{ messages[0].content }}"
    )));
    let prepared = Arc::new(PreparedTemplates::default());
    let barrier = Arc::new(Barrier::new(32));
    let threads = (0..32)
        .map(|i| {
            let artifacts = artifacts.clone();
            let prepared = prepared.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                let date = format!("2028-03-{:02}", i % 28 + 1);
                let content = format!("request-{i}");
                let request = request(&content, &date, false);
                barrier.wait();
                for _ in 0..8 {
                    assert_eq!(
                        prepared.render(&artifacts, &request).unwrap(),
                        format!("{date}|{content}")
                    );
                }
                prepared.plain.get().unwrap().as_ref().unwrap() as *const Environment<'static>
                    as usize
            })
        })
        .collect::<Vec<_>>();
    let pointers = threads
        .into_iter()
        .map(|thread| thread.join().unwrap())
        .collect::<Vec<_>>();
    assert!(pointers.iter().all(|pointer| *pointer == pointers[0]));
    assert!(prepared.tools.get().is_none());
    assert_eq!(
        prepared.plain.get().unwrap().as_ref().unwrap().fuel(),
        Some(RENDER_FUEL)
    );
    // A previously compiled dated template must still refuse an unowned clock.
    assert!(matches!(
        prepared.render(&artifacts, &request("later", "invalid", false)),
        Err(RenderError::DynamicTime)
    ));
}

#[test]
fn default_tool_variants_and_contract_specific_filters_stay_independent() {
    let artifacts = artifacts(json!([
        {"name":"default","template":"old"},
        {"name":"default","template":"plain {{ messages[0].content }}"},
        {"name":"tool_use","template":"tools {{ tools[0].function.name }}"}
    ]));
    let prepared = PreparedTemplates::default();
    assert_eq!(
        prepared
            .render(&artifacts, &request("one", "", false))
            .unwrap(),
        "plain one"
    );
    assert_eq!(
        prepared
            .render(&artifacts, &request("two", "", true))
            .unwrap(),
        "tools f"
    );
    assert_eq!(
        prepared
            .render(&artifacts, &request("three", "", false))
            .unwrap(),
        "plain three"
    );
    assert!(prepared.plain.get().is_some());
    assert!(prepared.tools.get().is_some());
    let mut nemotron = self::artifacts(json!("{{ true|string }}"));
    nemotron
        .model_config
        .insert("model_type".into(), json!("nemotron_h"));
    let ordinary = self::artifacts(json!("{{ true|string }}"));
    assert_eq!(
        PreparedTemplates::default()
            .render(&nemotron, &request("", "", false))
            .unwrap(),
        "True"
    );
    assert_eq!(
        PreparedTemplates::default()
            .render(&ordinary, &request("", "", false))
            .unwrap(),
        "true"
    );
}

#[test]
fn syntax_and_render_errors_do_not_poison_other_variants_or_requests() {
    let artifacts = artifacts(json!([
        {"name":"default","template":"{% if messages[0].content == 'bad' %}{{ raise_exception('no') }}{% endif %}ok"},
        {"name":"tool_use","template":"{% broken syntax %}"}
    ]));
    let prepared = PreparedTemplates::default();
    assert!(matches!(
        prepared.render(&artifacts, &request("bad", "", false)),
        Err(RenderError::Template)
    ));
    assert_eq!(
        prepared
            .render(&artifacts, &request("good", "", false))
            .unwrap(),
        "ok"
    );
    for _ in 0..2 {
        assert!(matches!(
            prepared.render(&artifacts, &request("good", "", true)),
            Err(RenderError::Template)
        ));
    }
    assert!(prepared.tools.get().unwrap().is_err());
    assert_eq!(
        prepared
            .render(&artifacts, &request("later", "", false))
            .unwrap(),
        "ok"
    );
}

#[test]
fn cached_environment_keeps_per_render_fuel_and_output_limits() {
    let bounded = artifacts(json!(
        "{% if messages[0].content == 'large' %}{{ 'x' * 16777217 }}{% else %}ok{% endif %}"
    ));
    let prepared = PreparedTemplates::default();
    assert!(matches!(
        prepared.render(&bounded, &request("large", "", false)),
        Err(RenderError::OutputTooLarge)
    ));
    assert_eq!(
        prepared
            .render(&bounded, &request("small", "", false))
            .unwrap(),
        "ok"
    );
    let bounded = artifacts(json!(
        "{% if messages[0].content == 'loop' %}{% for i in range(1000) %}x{% endfor %}{% else %}ok{% endif %}"
    ));
    let prepared = PreparedTemplates::default();
    let mut environment =
        compile_template(&bounded, bounded.chat_template.as_str().unwrap()).unwrap();
    environment.set_fuel(Some(32));
    assert!(prepared.plain.set(Ok(environment)).is_ok());
    for _ in 0..2 {
        assert!(matches!(
            prepared.render(&bounded, &request("loop", "", false)),
            Err(RenderError::Template)
        ));
        assert_eq!(
            prepared
                .render(&bounded, &request("small", "", false))
                .unwrap(),
            "ok"
        );
    }
}

#[test]
fn oversized_sources_render_ephemerally_without_retaining_either_variant() {
    // UTF-8 source bytes, not scalar count, determine retention eligibility.
    let large = format!("{{# {} #}}ok", "é".repeat(MAX_RETAINED_TEMPLATE_BYTES / 2));
    assert!(large.len() > MAX_RETAINED_TEMPLATE_BYTES);
    for oversized_tools in [false, true] {
        let template = json!([
            {"name":"default", "template": if oversized_tools { "small" } else { large.as_str() }},
            {"name":"tool_use", "template": if oversized_tools { large.as_str() } else { "small" }}
        ]);
        let artifacts = artifacts(template);
        let prepared = PreparedTemplates::default();
        for _ in 0..3 {
            assert_eq!(
                prepared
                    .render(&artifacts, &request("", "", oversized_tools))
                    .unwrap(),
                "ok"
            );
            assert_eq!(
                prepared
                    .render(&artifacts, &request("", "", !oversized_tools))
                    .unwrap(),
                "small"
            );
        }
        let (oversized, small) = if oversized_tools {
            (&prepared.tools, &prepared.plain)
        } else {
            (&prepared.plain, &prepared.tools)
        };
        assert!(
            oversized.get().is_none(),
            "oversized source populated a retained program slot"
        );
        assert!(small.get().is_some());
    }
    let mut template = "x".repeat(MAX_RETAINED_TEMPLATE_BYTES);
    let artifacts = artifacts(json!(template));
    let prepared = PreparedTemplates::default();
    assert_eq!(
        prepared
            .render(&artifacts, &request("", "", false))
            .unwrap()
            .len(),
        MAX_RETAINED_TEMPLATE_BYTES
    );
    assert!(
        prepared.plain.get().is_some(),
        "boundary-sized source should remain eligible"
    );
    template.push('x');
    let artifacts = self::artifacts(json!(template));
    let prepared = PreparedTemplates::default();
    assert_eq!(
        prepared
            .render(&artifacts, &request("", "", false))
            .unwrap()
            .len(),
        MAX_RETAINED_TEMPLATE_BYTES + 1
    );
    assert!(prepared.plain.get().is_none());
}

#[test]
fn imported_macro_without_context_keeps_request_owned_global_clock() {
    let artifacts = artifacts(json!(
        "{% macro date() %}{{ strftime_now('%Y-%m-%d') }}{% endmacro %}{% if not importing %}{% set importing = true %}{% from 'chat' import date as imported %}{{ imported() }}|{{ messages[0].content }}{% endif %}"
    ));
    let prepared = PreparedTemplates::default();
    for (content, date) in [
        ("first", "2028-03-01"),
        ("second", "2028-03-02"),
        ("first", "2028-03-01"),
    ] {
        assert_eq!(
            prepared
                .render(&artifacts, &request(content, date, false))
                .unwrap(),
            format!("{date}|{content}")
        );
    }
}
