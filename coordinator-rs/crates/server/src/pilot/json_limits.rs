//! Allocation-aware structural limits applied before typed JSON decoding.

use std::{cell::RefCell, fmt};

use serde::de::{self, DeserializeSeed, Error as _, MapAccess, SeqAccess, Visitor};
use thiserror::Error;

const MAXIMUM_DEPTH: usize = 32;
const MAXIMUM_VALUES: usize = 16_384;
const MAXIMUM_ITEMS_PER_ARRAY: usize = 4_096;
const MAXIMUM_FIELDS_PER_OBJECT: usize = 4_096;
const MAXIMUM_STRING_BYTES: usize = 1024 * 1024;
const MAXIMUM_TOTAL_STRING_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Default)]
struct StructuralState {
    values: usize,
    string_bytes: usize,
}

impl StructuralState {
    fn value<E: de::Error>(&mut self) -> Result<(), E> {
        self.values = self
            .values
            .checked_add(1)
            .ok_or_else(|| E::custom("JSON value count overflow"))?;
        if self.values > MAXIMUM_VALUES {
            return Err(E::custom(format_args!(
                "JSON contains more than {MAXIMUM_VALUES} values"
            )));
        }
        Ok(())
    }

    fn string<E: de::Error>(&mut self, value: &str) -> Result<(), E> {
        if value.len() > MAXIMUM_STRING_BYTES {
            return Err(E::custom(format_args!(
                "JSON string exceeds {MAXIMUM_STRING_BYTES} bytes"
            )));
        }
        self.string_bytes = self
            .string_bytes
            .checked_add(value.len())
            .ok_or_else(|| E::custom("JSON string byte count overflow"))?;
        if self.string_bytes > MAXIMUM_TOTAL_STRING_BYTES {
            return Err(E::custom(format_args!(
                "JSON strings exceed {MAXIMUM_TOTAL_STRING_BYTES} total bytes"
            )));
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct StructuralSeed<'a> {
    state: &'a RefCell<StructuralState>,
    depth: usize,
}

impl<'de> DeserializeSeed<'de> for StructuralSeed<'_> {
    type Value = ();

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(StructuralVisitor(self))
    }
}

struct StructuralVisitor<'a>(StructuralSeed<'a>);

impl StructuralVisitor<'_> {
    fn scalar<E: de::Error>(&self) -> Result<(), E> {
        self.0.state.borrow_mut().value()
    }

    fn string<E: de::Error>(&self, value: &str) -> Result<(), E> {
        let mut state = self.0.state.borrow_mut();
        state.value()?;
        state.string(value)
    }

    fn nested(&self) -> Result<StructuralSeed<'_>, &'static str> {
        if self.0.depth >= MAXIMUM_DEPTH {
            return Err("JSON nesting exceeds maximum depth 32");
        }
        Ok(StructuralSeed {
            state: self.0.state,
            depth: self.0.depth + 1,
        })
    }
}

impl<'de> Visitor<'de> for StructuralVisitor<'_> {
    type Value = ();

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("bounded JSON")
    }

    fn visit_bool<E: de::Error>(self, _: bool) -> Result<(), E> {
        self.scalar()
    }

    fn visit_i64<E: de::Error>(self, _: i64) -> Result<(), E> {
        self.scalar()
    }

    fn visit_u64<E: de::Error>(self, _: u64) -> Result<(), E> {
        self.scalar()
    }

    fn visit_f64<E: de::Error>(self, _: f64) -> Result<(), E> {
        self.scalar()
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<(), E> {
        self.string(value)
    }

    fn visit_borrowed_str<E: de::Error>(self, value: &'de str) -> Result<(), E> {
        self.string(value)
    }

    fn visit_string<E: de::Error>(self, value: String) -> Result<(), E> {
        self.string(&value)
    }

    fn visit_none<E: de::Error>(self) -> Result<(), E> {
        self.scalar()
    }

    fn visit_unit<E: de::Error>(self) -> Result<(), E> {
        self.scalar()
    }

    fn visit_some<D>(self, deserializer: D) -> Result<(), D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        self.0.deserialize(deserializer)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<(), A::Error>
    where
        A: SeqAccess<'de>,
    {
        self.scalar()?;
        let nested = self.nested().map_err(A::Error::custom)?;
        let mut items = 0_usize;
        while sequence.next_element_seed(nested)?.is_some() {
            items += 1;
            if items > MAXIMUM_ITEMS_PER_ARRAY {
                return Err(A::Error::custom(format_args!(
                    "JSON array contains more than {MAXIMUM_ITEMS_PER_ARRAY} items"
                )));
            }
        }
        Ok(())
    }

    fn visit_map<A>(self, mut object: A) -> Result<(), A::Error>
    where
        A: MapAccess<'de>,
    {
        self.scalar()?;
        let nested = self.nested().map_err(A::Error::custom)?;
        let mut fields = 0_usize;
        while let Some(key) = object.next_key::<String>()? {
            fields += 1;
            if fields > MAXIMUM_FIELDS_PER_OBJECT {
                return Err(A::Error::custom(format_args!(
                    "JSON object contains more than {MAXIMUM_FIELDS_PER_OBJECT} fields"
                )));
            }
            self.0.state.borrow_mut().string::<A::Error>(&key)?;
            object.next_value_seed(nested)?;
        }
        Ok(())
    }
}

/// Validates depth, cardinality, and string bounds without retaining a JSON
/// tree. Callers perform typed decoding only after this pass succeeds.
pub fn validate_json_structure(bytes: &[u8]) -> Result<(), JsonStructureError> {
    JsonStructureBudget::default().validate_next(bytes)
}

/// Cumulative structural budget for a sequence of independently encoded JSON
/// documents retained by one transform.
///
/// Non-stream response assembly parses many SSE payloads into one retained
/// value graph. Sharing this budget across those payloads prevents an attacker
/// from resetting the allocation limits at every event boundary.
#[derive(Default)]
pub(crate) struct JsonStructureBudget {
    state: StructuralState,
}

impl JsonStructureBudget {
    pub(crate) fn validate_next(&mut self, bytes: &[u8]) -> Result<(), JsonStructureError> {
        let candidate = RefCell::new(self.state.clone());
        validate_with_state(bytes, &candidate)?;
        self.state = candidate.into_inner();
        Ok(())
    }
}

fn validate_with_state(
    bytes: &[u8],
    state: &RefCell<StructuralState>,
) -> Result<(), JsonStructureError> {
    let seed = StructuralSeed { state, depth: 0 };
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    seed.deserialize(&mut deserializer)
        .and_then(|()| deserializer.end())
        .map_err(JsonStructureError::Invalid)
}

#[derive(Debug, Error)]
pub enum JsonStructureError {
    #[error("JSON structure is invalid or exceeds pilot limits: {0}")]
    Invalid(serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_deep_and_high_cardinality_json_before_typed_decode() {
        let mut deep = "0".to_owned();
        for _ in 0..=MAXIMUM_DEPTH {
            deep = format!("[{deep}]");
        }
        assert!(validate_json_structure(deep.as_bytes()).is_err());

        let tiny = format!(
            "[{}]",
            std::iter::repeat_n("{}", MAXIMUM_ITEMS_PER_ARRAY + 1)
                .collect::<Vec<_>>()
                .join(",")
        );
        assert!(validate_json_structure(tiny.as_bytes()).is_err());
    }

    #[test]
    fn cumulative_budget_cannot_reset_at_document_boundaries() {
        let tiny = format!(
            "[{}]",
            std::iter::repeat_n("{}", MAXIMUM_ITEMS_PER_ARRAY)
                .collect::<Vec<_>>()
                .join(",")
        );
        assert!(validate_json_structure(tiny.as_bytes()).is_ok());

        let mut budget = JsonStructureBudget::default();
        for _ in 0..3 {
            budget
                .validate_next(tiny.as_bytes())
                .expect("three documents remain under the cumulative value bound");
        }
        assert!(budget.validate_next(tiny.as_bytes()).is_err());
    }
}
