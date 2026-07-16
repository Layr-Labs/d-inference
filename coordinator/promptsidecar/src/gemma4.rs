use crate::normalize::NormalizeError;
use serde_json::Value;

mod arguments;
mod schema;
mod turn_structure;

pub(crate) fn applies(model_id: &str, model_type: Option<&str>) -> bool {
    match model_type {
        Some(model_type) => model_type.to_ascii_lowercase().starts_with("gemma4"),
        None => model_id.to_ascii_lowercase().contains("gemma-4"),
    }
}

pub(crate) fn normalize_messages(messages: Vec<Value>) -> Result<Vec<Value>, NormalizeError> {
    turn_structure::normalize(arguments::normalize(messages)?)
}

pub(crate) fn normalize_tools(tools: Vec<Value>) -> Vec<Value> {
    schema::normalize(tools)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_matches_swift_model_hint_precedence() {
        assert!(applies("gemma-4-26b", None));
        assert!(applies("alias", Some("gemma4_text")));
        assert!(!applies("gemma-4-26b", Some("gpt_oss")));
    }
}
