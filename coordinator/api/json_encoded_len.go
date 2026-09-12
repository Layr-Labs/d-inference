package api

// json_encoded_len.go computes len(json.Marshal(v)) for the value universe the
// inference request decoder produces — map[string]any, []any, string,
// json.Number, bool, nil — WITHOUT building the encoding. The billing prompt
// estimate is a byte count of the marshaled messages (a guaranteed BPE upper
// bound, see approximateTokenCountUpperBound), and marshaling a multi-MB
// inline-image body just to measure it was one of the largest allocations on
// the request path. The count mirrors encoding/json's encoder byte for byte
// (escaping rules from encoding/json/encode.go appendString and tables.go);
// anything outside the modeled universe reports ok=false so the caller falls
// back to the real encoder and the value can never drift.

import (
	"encoding/json"
	"unicode/utf8"
)

// jsonEncodedLen returns the exact length json.Marshal(v) would produce for a
// decoder-shaped value. ok=false means v contains a type (or an invalid
// json.Number) this counter does not model; the caller must then marshal.
func jsonEncodedLen(v any) (int, bool) {
	switch x := v.(type) {
	case nil:
		return len("null"), true
	case bool:
		if x {
			return len("true"), true
		}
		return len("false"), true
	case string:
		return jsonStringEncodedLen(x, true), true
	case json.Number:
		// encoding/json writes the literal verbatim, substituting "0" for the
		// zero-value Number and refusing anything that is not a JSON number.
		s := string(x)
		if s == "" {
			return 1, true
		}
		if !jsonNumberLiteralValid(s) {
			return 0, false
		}
		return len(s), true
	case map[string]any:
		if x == nil {
			return len("null"), true
		}
		n := 2
		if len(x) > 1 {
			n += len(x) - 1 // commas
		}
		for key, value := range x {
			m, ok := jsonEncodedLen(value)
			if !ok {
				return 0, false
			}
			n += jsonStringEncodedLen(key, true) + 1 + m // "key":value
		}
		return n, true
	case []any:
		if x == nil {
			return len("null"), true
		}
		n := 2
		if len(x) > 1 {
			n += len(x) - 1
		}
		for _, value := range x {
			m, ok := jsonEncodedLen(value)
			if !ok {
				return 0, false
			}
			n += m
		}
		return n, true
	default:
		return 0, false
	}
}

// jsonStringEncodedLen returns len(json.Marshal(s)) (quotes included) under
// the encoder's escaping rules: `"` `\` and the five short escapes cost one
// extra byte; other control bytes, and `<` `>` `&` when escapeHTML is set,
// become 6-byte \u00XX forms; every invalid UTF-8 byte becomes the 6-byte
// \ufffd; U+2028/U+2029 (3 bytes each) become 6-byte escapes unconditionally.
func jsonStringEncodedLen(s string, escapeHTML bool) int {
	n := 2 + len(s)
	for i := 0; i < len(s); {
		b := s[i]
		if b < utf8.RuneSelf {
			i++
			if b >= 0x20 && b != '"' && b != '\\' {
				if escapeHTML && (b == '<' || b == '>' || b == '&') {
					n += 5
				}
				continue
			}
			switch b {
			case '\\', '"', '\b', '\f', '\n', '\r', '\t':
				n++
			default:
				n += 5
			}
			continue
		}
		c, size := utf8.DecodeRuneInString(s[i:])
		if c == utf8.RuneError && size == 1 {
			n += 5 // one invalid byte → `\ufffd`
			i++
			continue
		}
		if c == '\u2028' || c == '\u2029' {
			n += 3 // three-byte rune → six-byte escape
		}
		i += size
	}
	return n
}

// jsonNumberLiteralValid reports whether s is a JSON number literal, matching
// encoding/json's isValidNumber (RFC 8259 section 6 grammar).
func jsonNumberLiteralValid(s string) bool {
	if s == "" {
		return false
	}
	if s[0] == '-' {
		s = s[1:]
		if s == "" {
			return false
		}
	}
	switch {
	case s[0] == '0':
		s = s[1:]
	case '1' <= s[0] && s[0] <= '9':
		s = s[1:]
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	default:
		return false
	}
	if len(s) >= 2 && s[0] == '.' && '0' <= s[1] && s[1] <= '9' {
		s = s[2:]
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	}
	if len(s) >= 2 && (s[0] == 'e' || s[0] == 'E') {
		s = s[1:]
		if s[0] == '+' || s[0] == '-' {
			s = s[1:]
			if s == "" {
				return false
			}
		}
		for len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
			s = s[1:]
		}
	}
	return s == ""
}
