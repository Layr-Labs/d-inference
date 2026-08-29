//! Predicates that reproduce Go `encoding/json` `omitempty` semantics.
//!
//! Go omits a field when its value is `false`, `0`, `0.0`, `""`, a nil
//! pointer, or a nil/empty slice/map. Each helper here matches one of those
//! cases so `#[serde(skip_serializing_if = ...)]` can mirror the Go tags
//! field-for-field.

/// Go `omitempty` on an `int`/`int64` field: omitted when zero.
pub(crate) fn is_zero_i64(v: &i64) -> bool {
    *v == 0
}

/// Go `omitempty` on a `float64` field: omitted when zero (including `-0.0`,
/// which compares equal to `0.0` in Go as well).
pub(crate) fn is_zero_f64(v: &f64) -> bool {
    *v == 0.0
}

/// Go `omitempty` on a `bool` field: omitted when `false`.
pub(crate) fn is_false(v: &bool) -> bool {
    !*v
}
