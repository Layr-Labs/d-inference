use crate::normalize::NormalizeError;
use serde_json::Value;
use std::collections::HashSet;

const MAX_ARRAY_ITEMS: usize = 16;
const MAX_GRAMMAR_COMPLEXITY: usize = 50_000;
const SCHEMA_FIXED_COST: usize = 8;
const NULLABLE_BRANCH_COST: usize = 4;
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
    // Normalization rewrites the allow-all `{}` / `true` schemas into a
    // render-safe marker shape that grammar modes compile as the free string
    // the original `{}` compiled to. Only that exact shape is accepted; any
    // other marker-bearing schema fails closed. Mirrors the Swift compiler.
    if let Some(marker) = schema.get(crate::normalize::ORIGINAL_BOOLEAN_SCHEMA_KEY) {
        // The parameters root must stay an object schema (mirrors the Swift
        // compiler, whose root guard rejects the string-shaped marker).
        if !root
            && marker == &Value::Bool(true)
            && schema.len() == 2
            && schema.get("type") == Some(&Value::String("string".into()))
        {
            return Ok(());
        }
        return Err(NormalizeError::InvalidTools);
    }
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
            "integer" => json_number_is_integer(value),
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

fn json_number_is_integer(value: &Value) -> bool {
    if value.as_i64().is_some() {
        return true;
    }
    value.as_f64().is_some_and(|number| {
        number.is_finite() && number.fract() == 0.0 && number.abs() < 9_007_199_254_740_992.0
    })
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
            let count = constrained_nonnegative(schema.get("maxItems"))
                .ok()
                .flatten()
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
        Some(Value::Number(value)) => exact_nonnegative_usize(value)
            .map(Some)
            .ok_or(NormalizeError::InvalidTools),
        Some(_) => Err(NormalizeError::InvalidTools),
    }
}

// JSON Schema's integer domain is mathematical, not lexical: 1, 1.0, and
// 1e0 are the same integer. Parse serde_json's canonical decimal spelling
// exactly so a rounded f64 can never turn a fractional bound into an integer.
fn exact_nonnegative_usize(value: &serde_json::Number) -> Option<usize> {
    let raw = value.to_string();
    exact_nonnegative_literal(&raw)
}

fn exact_nonnegative_literal(raw: &str) -> Option<usize> {
    if raw.starts_with('-') {
        return None;
    }
    let (coefficient, exponent) = match raw.find(['e', 'E']) {
        Some(index) => (&raw[..index], raw[index + 1..].parse::<i64>().ok()?),
        None => (raw, 0),
    };
    let (whole, fraction) = coefficient
        .split_once('.')
        .map_or((coefficient, ""), |parts| parts);
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    let mut digits = String::with_capacity(whole.len() + fraction.len());
    digits.push_str(whole);
    digits.push_str(fraction);
    let scale = i64::try_from(fraction.len()).ok()?.checked_sub(exponent)?;
    if scale > 0 {
        let fractional_digits = usize::try_from(scale).ok()?;
        if fractional_digits >= digits.len() {
            if digits.bytes().any(|byte| byte != b'0') {
                return None;
            }
            digits.clear();
            digits.push('0');
        } else {
            let split = digits.len() - fractional_digits;
            if digits[split..].bytes().any(|byte| byte != b'0') {
                return None;
            }
            digits.truncate(split);
        }
    } else if scale < 0 {
        let zeros = usize::try_from(scale.checked_neg()?).ok()?;
        if zeros > usize::BITS as usize {
            return None;
        }
        digits.extend(std::iter::repeat_n('0', zeros));
    }
    digits.parse().ok()
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
    fn accepts_exact_integral_decimal_array_bounds() {
        for bounds in [
            json!({"minItems":1.0,"maxItems":2.0}),
            serde_json::from_str::<Value>(r#"{"minItems":1e0,"maxItems":2e0}"#)
                .expect("scientific bounds"),
        ] {
            let mut array = json!({
                "type": "array",
                "items": {"type": "string"}
            });
            array
                .as_object_mut()
                .expect("array schema")
                .extend(bounds.as_object().expect("bounds").clone());
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
            assert!(validate_constrained_tools(&tools).is_ok());
        }
        assert!(
            exact_nonnegative_usize(&serde_json::Number::from_f64(1.5).expect("number")).is_none()
        );
    }

    #[test]
    fn accepts_mathematical_integer_finite_values() {
        for literal in ["1.0", "1e0", "-2.0", "-2e0"] {
            let tools: Vec<Value> = serde_json::from_str(&format!(
                r#"[{{"type":"function","function":{{
                    "name":"calculate",
                    "parameters":{{"type":"object","properties":{{
                        "value":{{"type":"integer","const":{literal}}}
                    }}}}
                }}}}]"#
            ))
            .expect("integer tool schema");
            assert!(validate_constrained_tools(&tools).is_ok(), "{literal}");
        }
    }

    #[test]
    fn rejects_integer_decimal_outside_exact_double_range() {
        // The coordinator and Swift provider can retain wider integral values,
        // but serde_json's render-safe number representation cannot preserve a
        // decimal spelling outside the exact f64 range. Prompt planning therefore
        // rejects this rare shape and fails cold instead of deriving a wrong cache
        // key; ordinary inference remains available.
        let tools = vec![json!({
            "type": "function",
            "function": {
                "name": "calculate",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "value": {
                            "type": "integer",
                            "const": 9_007_199_254_740_992.0_f64
                        }
                    }
                }
            }
        })];
        assert!(validate_constrained_tools(&tools).is_err());
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
