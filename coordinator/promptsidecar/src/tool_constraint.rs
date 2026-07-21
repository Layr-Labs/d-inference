use crate::normalize::NormalizeError;
use serde_json::Value;
use std::collections::HashSet;

const MAX_ARRAY_ITEMS: usize = 16;
const MAX_GRAMMAR_COMPLEXITY: usize = 50_000;
const SCHEMA_FIXED_COST: usize = 8;
const NULLABLE_BRANCH_COST: usize = 4;
const MAX_SAFE_AUTO_PATTERN_BYTES: usize = 128;
const MAX_SAFE_AUTO_PATTERN_COUNT: usize = 32;
const MAX_AUTO_PATTERN_DEPTH: usize = 32;
const STRING_DELIMITERS: [&str; 6] = [
    r#"<|"|>"#,
    "<escape>",
    "<|tool_call>",
    "<tool_call|>",
    "<start_function_call>",
    "<end_function_call>",
];

pub(crate) fn validate_constrained_tools(tools: &[Value]) -> Result<(), NormalizeError> {
    validate_constrained_tools_for(tools, None)
}

pub(crate) fn validate_selected_constrained_tool(
    tools: &[Value],
    selected: &str,
) -> Result<(), NormalizeError> {
    validate_constrained_tools_for(tools, Some(selected))
}

pub(crate) fn validate_auto_tool_patterns(tools: &[Value]) -> Result<(), NormalizeError> {
    for tool in tools {
        let parameters = tool
            .as_object()
            .and_then(|tool| tool.get("function"))
            .and_then(Value::as_object)
            .and_then(|function| function.get("parameters"));
        if let Some(parameters) = parameters {
            validate_auto_schema_patterns(parameters, 0)?;
        }
    }
    Ok(())
}

fn validate_constrained_tools_for(
    tools: &[Value],
    selected: Option<&str>,
) -> Result<(), NormalizeError> {
    if tools.len() > 64 {
        return Err(NormalizeError::InvalidTools);
    }
    let mut grammar_complexity = 0;
    for tool in tools {
        let function = tool
            .as_object()
            .and_then(|tool| tool.get("function"))
            .and_then(Value::as_object)
            .ok_or(NormalizeError::InvalidTools)?;
        let name = function
            .get("name")
            .and_then(Value::as_str)
            .ok_or(NormalizeError::InvalidTools)?;
        if selected.is_some_and(|selected| selected != name) {
            continue;
        }
        let schema_cost = match function.get("parameters") {
            None | Some(Value::Null) => 2,
            Some(schema) => {
                validate_constrained_schema(schema, true, 0)?;
                constrained_schema_grammar_cost(schema)
            }
        };
        grammar_complexity = grammar_add(grammar_complexity, grammar_add(name.len(), schema_cost));
        if grammar_complexity > MAX_GRAMMAR_COMPLEXITY {
            return Err(NormalizeError::InvalidTools);
        }
    }
    Ok(())
}

fn validate_constrained_schema(
    schema: &Value,
    root: bool,
    depth: usize,
) -> Result<(), NormalizeError> {
    if depth > 16 {
        return Err(NormalizeError::InvalidTools);
    }
    let schema = schema.as_object().ok_or(NormalizeError::InvalidTools)?;
    let supported = [
        "type",
        "properties",
        "required",
        "additionalProperties",
        "items",
        "minItems",
        "maxItems",
        "nullable",
        "enum",
        "const",
        "description",
        "title",
        "default",
        "examples",
        "deprecated",
        "readOnly",
        "writeOnly",
    ];
    if schema.keys().any(|key| !supported.contains(&key.as_str())) {
        return Err(NormalizeError::InvalidTools);
    }
    let (kind, nullable) = constrained_schema_type(schema)?;
    let nullable = match schema.get("nullable") {
        None => nullable,
        Some(Value::Bool(value)) => nullable || *value,
        Some(_) => return Err(NormalizeError::InvalidTools),
    };
    if root && (kind != "object" || nullable) {
        return Err(NormalizeError::InvalidTools);
    }
    validate_finite_values(schema, &kind, nullable)?;
    match kind.as_str() {
        "object" => {
            let properties = match schema.get("properties") {
                None => None,
                Some(Value::Object(properties)) => Some(properties),
                Some(_) => return Err(NormalizeError::InvalidTools),
            };
            if properties.is_some_and(|properties| properties.len() > 128) {
                return Err(NormalizeError::InvalidTools);
            }
            if let Some(properties) = properties {
                for (name, child) in properties {
                    if name.is_empty()
                        || name.len() > 64
                        || !name.bytes().all(|byte| {
                            byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'
                        })
                    {
                        return Err(NormalizeError::InvalidTools);
                    }
                    validate_constrained_schema(child, false, depth + 1)?;
                }
                if let Some(Value::Array(required)) = schema.get("required") {
                    let mut seen = HashSet::new();
                    for member in required {
                        let name = member.as_str().ok_or(NormalizeError::InvalidTools)?;
                        if !properties.contains_key(name) || !seen.insert(name) {
                            return Err(NormalizeError::InvalidTools);
                        }
                    }
                } else if schema.get("required").is_some() {
                    return Err(NormalizeError::InvalidTools);
                }
            } else if let Some(required) = schema.get("required")
                && required
                    .as_array()
                    .is_none_or(|required| !required.is_empty())
            {
                return Err(NormalizeError::InvalidTools);
            }
            if schema
                .get("additionalProperties")
                .is_some_and(|value| !value.is_boolean())
            {
                return Err(NormalizeError::InvalidTools);
            }
        }
        "array" => {
            validate_constrained_schema(
                schema.get("items").ok_or(NormalizeError::InvalidTools)?,
                false,
                depth + 1,
            )?;
            let min = constrained_nonnegative(schema.get("minItems"))?.unwrap_or(0);
            let max = constrained_nonnegative(schema.get("maxItems"))?;
            if min > MAX_ARRAY_ITEMS || max.is_some_and(|max| max > MAX_ARRAY_ITEMS || max < min) {
                return Err(NormalizeError::InvalidTools);
            }
        }
        "string" | "boolean" | "integer" | "number" | "null" => {}
        _ => return Err(NormalizeError::InvalidTools),
    }
    Ok(())
}

fn validate_auto_schema_patterns(schema: &Value, depth: usize) -> Result<(), NormalizeError> {
    if depth > MAX_AUTO_PATTERN_DEPTH {
        return Err(NormalizeError::InvalidTools);
    }
    match schema {
        Value::Array(values) => {
            for child in values {
                validate_auto_schema_patterns(child, depth + 1)?;
            }
        }
        Value::Object(object) => {
            if object.contains_key("$ref") {
                return Err(NormalizeError::InvalidTools);
            }
            if ["if", "then", "else"]
                .iter()
                .any(|keyword| object.contains_key(*keyword))
            {
                return Err(NormalizeError::InvalidTools);
            }
            if [
                "dependentSchemas",
                "dependentRequired",
                "dependencies",
                "propertyNames",
                "unevaluatedItems",
                "unevaluatedProperties",
            ]
            .iter()
            .any(|keyword| object.contains_key(*keyword))
            {
                return Err(NormalizeError::InvalidTools);
            }
            // Mixed-type const/enum on a typeless node has no single
            // renderable type; normalization would silently reject every
            // member outside its picked type. Mirrors the multi-type union
            // policy.
            if !object.contains_key("type")
                && let Some((concrete, _)) = crate::normalize::finite_value_types(object)
                && concrete.len() > 1
            {
                return Err(NormalizeError::InvalidTools);
            }
            if let Some(types) = object.get("type").and_then(Value::as_array) {
                let mut concrete = std::collections::HashSet::new();
                for raw_type in types {
                    let raw_type = raw_type.as_str().ok_or(NormalizeError::InvalidTools)?;
                    if !raw_type.eq_ignore_ascii_case("null") {
                        concrete.insert(raw_type.to_ascii_lowercase());
                    }
                }
                if concrete.len() > 1 {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            for keyword in ["anyOf", "oneOf"] {
                let Some(variants) = object.get(keyword).and_then(Value::as_array) else {
                    continue;
                };
                let mut concrete = std::collections::HashSet::new();
                for variant in variants {
                    let variant = variant.as_object().ok_or(NormalizeError::InvalidTools)?;
                    let members = raw_schema_concrete_types(
                        variant.get("type").ok_or(NormalizeError::InvalidTools)?,
                    )?;
                    concrete.extend(members);
                }
                if concrete.len() > 1 {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            if let Some(pattern) = object.get("pattern") {
                let pattern = pattern.as_str().ok_or(NormalizeError::InvalidTools)?;
                if !safe_auto_schema_pattern(pattern) {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            if let Some(patterns) = object.get("patternProperties") {
                let patterns = patterns.as_object().ok_or(NormalizeError::InvalidTools)?;
                if patterns.len() > MAX_SAFE_AUTO_PATTERN_COUNT {
                    return Err(NormalizeError::InvalidTools);
                }
                if patterns
                    .keys()
                    .any(|pattern| !safe_auto_schema_pattern(pattern))
                {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            for key in [
                "additionalProperties",
                "additionalItems",
                "contains",
                "contentSchema",
                "if",
                "then",
                "else",
                "not",
                "propertyNames",
                "unevaluatedItems",
                "unevaluatedProperties",
            ] {
                if let Some(child) = object.get(key) {
                    validate_auto_schema_patterns(child, depth + 1)?;
                }
            }
            for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
                if let Some(children) = object.get(key).and_then(Value::as_array) {
                    for child in children {
                        validate_auto_schema_patterns(child, depth + 1)?;
                    }
                }
            }
            if let Some(items) = object.get("items") {
                if let Some(tuple) = items.as_array() {
                    for child in tuple {
                        validate_auto_schema_patterns(child, depth + 1)?;
                    }
                } else {
                    validate_auto_schema_patterns(items, depth + 1)?;
                }
            }
            for key in [
                "properties",
                "patternProperties",
                "dependentSchemas",
                "dependencies",
                "definitions",
                "$defs",
            ] {
                if let Some(children) = object.get(key).and_then(Value::as_object) {
                    for child in children.values() {
                        validate_auto_schema_patterns(child, depth + 1)?;
                    }
                }
            }
        }
        _ => {}
    }
    Ok(())
}

fn raw_schema_concrete_types(
    raw: &Value,
) -> Result<std::collections::HashSet<String>, NormalizeError> {
    let mut concrete = std::collections::HashSet::new();
    match raw {
        Value::String(member) => {
            if !member.eq_ignore_ascii_case("null") {
                concrete.insert(member.to_ascii_lowercase());
            }
        }
        Value::Array(members) => {
            for member in members {
                let member = member.as_str().ok_or(NormalizeError::InvalidTools)?;
                if !member.eq_ignore_ascii_case("null") {
                    concrete.insert(member.to_ascii_lowercase());
                }
            }
        }
        _ => return Err(NormalizeError::InvalidTools),
    }
    Ok(concrete)
}

fn safe_auto_schema_pattern(pattern: &str) -> bool {
    if pattern.len() > MAX_SAFE_AUTO_PATTERN_BYTES {
        return false;
    }
    let literal = pattern.strip_prefix('^').unwrap_or(pattern);
    let literal = literal.strip_suffix('$').unwrap_or(literal);
    !literal.bytes().any(|byte| {
        matches!(
            byte,
            b'\\'
                | b'.'
                | b'^'
                | b'$'
                | b'|'
                | b'?'
                | b'*'
                | b'+'
                | b'('
                | b')'
                | b'['
                | b']'
                | b'{'
                | b'}'
        )
    })
}

fn validate_finite_values(
    schema: &serde_json::Map<String, Value>,
    kind: &str,
    nullable: bool,
) -> Result<(), NormalizeError> {
    let constant = schema.get("const");
    let enumeration = schema.get("enum");
    if constant.is_some() && enumeration.is_some() {
        return Err(NormalizeError::InvalidTools);
    }
    let values: Vec<&Value> = if let Some(constant) = constant {
        vec![constant]
    } else if let Some(enumeration) = enumeration {
        let values = enumeration.as_array().ok_or(NormalizeError::InvalidTools)?;
        if values.is_empty() || values.len() > 128 {
            return Err(NormalizeError::InvalidTools);
        }
        values.iter().collect()
    } else {
        return Ok(());
    };
    if matches!(kind, "object" | "array" | "number") {
        return Err(NormalizeError::InvalidTools);
    }
    for value in values {
        if value.is_null() && nullable {
            continue;
        }
        if kind == "string"
            && value
                .as_str()
                .is_some_and(|text| STRING_DELIMITERS.iter().any(|marker| text.contains(marker)))
        {
            return Err(NormalizeError::InvalidTools);
        }
        let matches = match kind {
            "string" => value.is_string(),
            "boolean" => value.is_boolean(),
            "integer" => value.as_i64().is_some(),
            "number" => value.as_f64().is_some_and(f64::is_finite),
            "null" => value.is_null(),
            _ => false,
        };
        if !matches {
            return Err(NormalizeError::InvalidTools);
        }
    }
    Ok(())
}

fn constrained_schema_type(
    schema: &serde_json::Map<String, Value>,
) -> Result<(String, bool), NormalizeError> {
    match schema.get("type") {
        None | Some(Value::Null) => {
            if schema.contains_key("properties") || schema.contains_key("additionalProperties") {
                Ok(("object".into(), false))
            } else if schema.contains_key("items") {
                Ok(("array".into(), false))
            } else {
                Ok(("string".into(), false))
            }
        }
        Some(Value::String(kind)) => Ok((kind.to_ascii_lowercase(), false)),
        Some(Value::Array(types)) => {
            let mut non_null = None;
            let mut saw_null = false;
            for value in types {
                let kind = value.as_str().ok_or(NormalizeError::InvalidTools)?;
                if kind.eq_ignore_ascii_case("null") {
                    saw_null = true;
                } else if non_null.replace(kind).is_some() {
                    return Err(NormalizeError::InvalidTools);
                }
            }
            match (non_null, saw_null) {
                (Some(kind), true) => Ok((kind.to_ascii_lowercase(), true)),
                _ => Err(NormalizeError::InvalidTools),
            }
        }
        Some(_) => Err(NormalizeError::InvalidTools),
    }
}

fn constrained_schema_grammar_cost(schema: &Value) -> usize {
    let Some(schema) = schema.as_object() else {
        return MAX_GRAMMAR_COMPLEXITY + 1;
    };
    let Ok((kind, mut nullable)) = constrained_schema_type(schema) else {
        return MAX_GRAMMAR_COMPLEXITY + 1;
    };
    match schema.get("nullable") {
        None => {}
        Some(Value::Bool(value)) => nullable |= *value,
        Some(_) => return MAX_GRAMMAR_COMPLEXITY + 1,
    }
    let finite_values: Option<Vec<&Value>> = if let Some(constant) = schema.get("const") {
        Some(vec![constant])
    } else {
        schema
            .get("enum")
            .and_then(Value::as_array)
            .map(|values| values.iter().collect())
    };
    // JSON Schema applies type and enum/const conjunctively: a nullable type
    // admits null only when the finite value set itself contains null, so
    // the provider grammar builds no null branch (and none is charged).
    if let Some(values) = &finite_values
        && !values.iter().any(|value| value.is_null())
    {
        nullable = false;
    }
    let base_cost = if nullable {
        grammar_add(SCHEMA_FIXED_COST, NULLABLE_BRANCH_COST)
    } else {
        SCHEMA_FIXED_COST
    };
    let payload_cost = match kind.as_str() {
        "object" => {
            let mut cost = 2;
            if let Some(properties) = schema.get("properties").and_then(Value::as_object) {
                for (name, child) in properties {
                    cost = grammar_add(
                        cost,
                        grammar_add(name.len() + 2, constrained_schema_grammar_cost(child)),
                    );
                }
            }
            cost
        }
        "array" => {
            let count = schema
                .get("maxItems")
                .and_then(Value::as_u64)
                .and_then(|value| usize::try_from(value).ok())
                .unwrap_or(MAX_ARRAY_ITEMS);
            let item_cost = schema
                .get("items")
                .map(constrained_schema_grammar_cost)
                .unwrap_or(MAX_GRAMMAR_COMPLEXITY + 1);
            grammar_add(2, grammar_multiply(grammar_add(item_cost, 1), count))
        }
        "string" => finite_values.map_or(16, |values| {
            values.into_iter().fold(0, |cost, value| {
                value
                    .as_str()
                    .map_or(cost, |text| grammar_add(cost, text.len() + 10))
            })
        }),
        "boolean" => finite_values.map_or(10, |values| {
            grammar_multiply(
                values
                    .into_iter()
                    .filter(|value| value.is_boolean())
                    .count(),
                5,
            )
        }),
        "integer" | "number" => {
            finite_values.map_or(if kind == "integer" { 20 } else { 40 }, |values| {
                values.into_iter().fold(0, |cost, value| {
                    value
                        .as_number()
                        .map_or(cost, |number| grammar_add(cost, number.to_string().len()))
                })
            })
        }
        "null" => 4,
        _ => MAX_GRAMMAR_COMPLEXITY + 1,
    };
    grammar_add(base_cost, payload_cost)
}

fn grammar_add(lhs: usize, rhs: usize) -> usize {
    lhs.checked_add(rhs)
        .filter(|value| *value <= MAX_GRAMMAR_COMPLEXITY)
        .unwrap_or(MAX_GRAMMAR_COMPLEXITY + 1)
}

fn grammar_multiply(lhs: usize, rhs: usize) -> usize {
    lhs.checked_mul(rhs)
        .filter(|value| *value <= MAX_GRAMMAR_COMPLEXITY)
        .unwrap_or(MAX_GRAMMAR_COMPLEXITY + 1)
}

fn constrained_nonnegative(raw: Option<&Value>) -> Result<Option<usize>, NormalizeError> {
    match raw {
        None => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .map(Some)
            .ok_or(NormalizeError::InvalidTools),
        Some(_) => Err(NormalizeError::InvalidTools),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn infers_structural_types_and_case_insensitive_null() {
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "lookup",
                "parameters": {
                    "properties": {
                        "value": {
                            "type": ["STRING", "NULL"]
                        }
                    }
                }
            }
        })];
        assert!(validate_constrained_tools(&tools).is_ok());
    }

    #[test]
    fn rejects_grammar_complexity_before_provider_dispatch() {
        let mut value = json!({"type": "string"});
        for _ in 0..4 {
            value = json!({
                "type": "array",
                "items": value,
                "maxItems": 16
            });
        }
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "expand",
                "parameters": {
                    "type": "object",
                    "properties": {"value": value}
                }
            }
        })];
        assert!(validate_constrained_tools(&tools).is_err());
    }

    #[test]
    fn rejects_null_array_bounds() {
        for bound in ["minItems", "maxItems"] {
            let mut array = json!({
                "type": "array",
                "items": {"type": "string"}
            });
            array
                .as_object_mut()
                .expect("array schema")
                .insert(bound.into(), Value::Null);
            let tools = vec![json!({
                "type": "function",
                "function": {
                    "name": "expand",
                    "parameters": {
                        "type": "object",
                        "properties": {"values": array}
                    }
                }
            })];
            assert!(validate_constrained_tools(&tools).is_err(), "{bound}");
        }
    }

    #[test]
    fn charges_null_branch_only_when_enum_admits_null() {
        let plain = constrained_schema_grammar_cost(&json!({"type":"string","enum":["ok"]}));
        let without_null =
            constrained_schema_grammar_cost(&json!({"type":["string","null"],"enum":["ok"]}));
        assert_eq!(without_null, plain);
        let with_null =
            constrained_schema_grammar_cost(&json!({"type":["string","null"],"enum":["ok",null]}));
        assert_eq!(with_null, plain + NULLABLE_BRANCH_COST);
    }

    #[test]
    fn charges_nullable_branches_to_the_grammar_budget() {
        let properties = (0..128)
            .map(|index| {
                (
                    format!("p{index}"),
                    json!({"type": ["string", "null"], "enum": [null]}),
                )
            })
            .collect::<serde_json::Map<String, Value>>();
        let tools = (0..64)
            .map(|index| {
                json!({
                    "type": "function",
                    "function": {
                        "name": format!("tool{index}"),
                        "parameters": {
                            "type": "object",
                            "properties": properties.clone()
                        }
                    }
                })
            })
            .collect::<Vec<_>>();
        assert!(validate_constrained_tools(&tools).is_err());
    }

    #[test]
    fn rejects_number_enum_and_const_values() {
        for value in [
            json!(9_007_199_254_740_993_u64),
            json!(9_223_372_036_854_775_807_u64),
            json!(9_007_199_254_740_994.0_f64),
            json!(-9_007_199_254_740_994.0_f64),
            json!(0.1_f64),
        ] {
            let tools = vec![json!({
                "type": "function",
                "function": {
                    "name": "calculate",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "value": {"type": "number", "const": value}
                        }
                    }
                }
            })];
            assert!(validate_constrained_tools(&tools).is_err());
        }
    }

    #[test]
    fn rejects_every_gemma_parser_delimiter_in_strings() {
        for marker in STRING_DELIMITERS {
            let tools = vec![json!({
                "type": "function",
                "function": {
                    "name": "echo",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "value": {
                                "type": "string",
                                "const": format!("before{marker}after")
                            }
                        }
                    }
                }
            })];
            assert!(validate_constrained_tools(&tools).is_err(), "{marker}");
        }
    }
}
