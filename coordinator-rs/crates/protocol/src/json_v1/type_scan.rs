//! Lightweight top-level key scanner, a line-for-line mirror of
//! `coordinator/protocol/type_scan.go`.
//!
//! [`peek_type`] reads the message `type` without a full JSON parse so every
//! frame — including one per streamed token — is fully parsed exactly once.
//!
//! The scanner is deliberately conservative: whenever it meets anything it is
//! not 100% sure about (escape sequences, non-string type values, malformed
//! input, duplicate or case-variant keys) it reports `None` and the caller
//! falls back to the full envelope decode. It never needs to be *complete*,
//! only never-wrong.

/// Returns the raw string value of the top-level `"type"` key, or `None`
/// when the caller must fall back to a full envelope decode.
pub fn peek_type(data: &[u8]) -> Option<&str> {
    scan_top_level_string(data, "type")
}

/// Returns the raw string value of a top-level object key. `None` when the
/// key is absent, appears more than once (including ASCII case-variants —
/// like Go, `encoding/json` matches keys case-insensitively and
/// last-match-wins), its value is not a plain (escape-free) string, or the
/// input isn't a well-formed-enough object. Bailing on duplicates keeps the
/// fast path behaviorally identical to a full decode.
pub(crate) fn scan_top_level_string<'a>(data: &'a [u8], key: &str) -> Option<&'a str> {
    let mut i = skip_ws(data, 0);
    if i >= data.len() || data[i] != b'{' {
        return None;
    }
    i = skip_ws(data, i + 1);
    if i < data.len() && data[i] == b'}' {
        return None;
    }
    let mut found: Option<&[u8]> = None;
    loop {
        let (k, next) = scan_simple_string(data, i)?;
        i = skip_ws(data, next);
        if i >= data.len() || data[i] != b':' {
            return None;
        }
        i = skip_ws(data, i + 1);
        if k.eq_ignore_ascii_case(key.as_bytes()) {
            // A repeated key, or a case-variant ("Type") that a full decode
            // would also match: defer to the full decode. Real provider
            // frames never emit duplicates; correctness beats speed here.
            if found.is_some() || k != key.as_bytes() {
                return None;
            }
            let (v, v_next) = scan_simple_string(data, i)?;
            found = Some(v);
            i = v_next;
        } else {
            i = skip_value(data, i)?;
        }
        i = skip_ws(data, i);
        if i >= data.len() {
            return None;
        }
        match data[i] {
            b',' => i = skip_ws(data, i + 1),
            b'}' => return found.and_then(|v| std::str::from_utf8(v).ok()),
            _ => return None,
        }
    }
}

fn skip_ws(data: &[u8], mut i: usize) -> usize {
    while i < data.len() {
        match data[i] {
            b' ' | b'\t' | b'\n' | b'\r' => i += 1,
            _ => return i,
        }
    }
    i
}

/// Scans a JSON string starting at `data[i]` and returns its raw bytes and
/// the index after the closing quote. Bails on any escape sequence so it
/// never has to implement unescaping.
fn scan_simple_string(data: &[u8], mut i: usize) -> Option<(&[u8], usize)> {
    if i >= data.len() || data[i] != b'"' {
        return None;
    }
    i += 1;
    let start = i;
    while i < data.len() {
        match data[i] {
            b'\\' => return None,
            b'"' => return Some((&data[start..i], i + 1)),
            _ => i += 1,
        }
    }
    None
}

/// Advances past one JSON value (string, object, array, number, bool, or
/// null) starting at `data[i]`, returning the index just after it.
fn skip_value(data: &[u8], mut i: usize) -> Option<usize> {
    if i >= data.len() {
        return None;
    }
    match data[i] {
        b'"' => skip_string(data, i),
        b'{' | b'[' => {
            let mut depth = 0usize;
            while i < data.len() {
                match data[i] {
                    b'"' => {
                        i = skip_string(data, i)?;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(i + 1);
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
            None
        }
        _ => {
            // Number, true, false, or null: scan to the next structural byte.
            while i < data.len() {
                match data[i] {
                    b',' | b'}' | b']' | b' ' | b'\t' | b'\n' | b'\r' => return Some(i),
                    _ => i += 1,
                }
            }
            None
        }
    }
}

/// Advances past the JSON string starting at `data[i]` (which must be `"`),
/// handling escape sequences.
fn skip_string(data: &[u8], mut i: usize) -> Option<usize> {
    i += 1;
    while i < data.len() {
        match data[i] {
            b'\\' => i += 2,
            b'"' => return Some(i + 1),
            _ => i += 1,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::peek_type;

    #[test]
    fn simple_frame() {
        assert_eq!(
            peek_type(br#"{"type":"heartbeat","status":"ok"}"#),
            Some("heartbeat")
        );
    }

    #[test]
    fn type_not_first_key() {
        assert_eq!(
            peek_type(br#"{"request_id":"r1","nested":{"type":"decoy"},"type":"cancel"}"#),
            Some("cancel")
        );
    }

    #[test]
    fn whitespace_and_arrays() {
        assert_eq!(
            peek_type(b" { \"models\" : [ {\"type\": 1}, [\"]\"] ] , \"type\" : \"register\" } "),
            Some("register")
        );
    }

    #[test]
    fn bails_on_escapes_in_value() {
        assert_eq!(peek_type(br#"{"type":"heart\u0062eat"}"#), None);
    }

    #[test]
    fn bails_on_duplicate_key() {
        assert_eq!(peek_type(br#"{"type":"a","type":"b"}"#), None);
    }

    #[test]
    fn bails_on_case_variant_key() {
        assert_eq!(peek_type(br#"{"Type":"a"}"#), None);
        assert_eq!(peek_type(br#"{"type":"a","TYPE":"b"}"#), None);
    }

    #[test]
    fn bails_on_non_string_value() {
        assert_eq!(peek_type(br#"{"type":42}"#), None);
        assert_eq!(peek_type(br#"{"type":null}"#), None);
    }

    #[test]
    fn bails_on_malformed_input() {
        assert_eq!(peek_type(b""), None);
        assert_eq!(peek_type(b"{}"), None);
        assert_eq!(peek_type(b"[1,2]"), None);
        assert_eq!(peek_type(br#"{"type":"a""#), None);
        assert_eq!(peek_type(br#"{"a":1}"#), None);
        assert_eq!(peek_type(br#"{"a" 1,"type":"x"}"#), None);
    }

    #[test]
    fn skips_escaped_strings_in_other_values() {
        assert_eq!(
            peek_type(br#"{"data":"a\"}{\\","type":"inference_response_chunk"}"#),
            Some("inference_response_chunk")
        );
    }
}
