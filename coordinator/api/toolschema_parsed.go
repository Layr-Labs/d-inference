package api

// toolschema_parsed.go is the parsed-map twin of NormalizeToolSchemas
// (toolschema.go). The inference prelude used to normalize tool schemas on the
// raw bytes (parse → repair → re-encode) and then parse the result again for
// the handler, and the tool-constraint validator parsed the ORIGINAL bytes a
// third time because it must see the pre-normalization schemas. Normalizing
// the already-decoded body instead makes the request cost one parse: the
// tools subtree is deep-copied first (the repair walk mutates in place), the
// copy is repaired, and the caller's untouched tools value is handed back for
// constraint validation.
//
// Byte-identity with the bytes path: when a repair is made, the bytes path's
// re-encode→re-decode round trip replaces every invalid UTF-8 byte in every
// string and key of the WHOLE body with U+FFFD (encoding/json writes such
// bytes as �). The provider body is marshaled from the parsed map, so the
// map-level path applies that same replacement when — and only when — a
// repair was made, keeping the sealed bytes identical to the old path.

import (
	"bytes"
	"strings"
	"unicode/utf8"
)

// normalizeParsedToolSchemas repairs the tool JSON-Schemas of an already
// decoded request in place, with the same gates as NormalizeToolSchemas,
// measured against rawBody (the caller's input bytes): bodies over
// maxToolNormalizationBytes, bodies without the literal `"tools"` key bytes
// (an escaped spelling of the key is forwarded verbatim, exactly as the bytes
// path always did), and bodies whose "tools" is not an array are left
// untouched. When a repair was made it returns the caller's
// original tools value (never mutated) and changed=true; otherwise (nil,
// false) and parsed is exactly as it was.
func normalizeParsedToolSchemas(parsed map[string]any, rawBody []byte) (originalTools []any, changed bool) {
	if len(rawBody) > maxToolNormalizationBytes || !bytes.Contains(rawBody, toolsKeyNeedle) {
		return nil, false
	}
	tools, ok := parsed["tools"].([]any)
	if !ok {
		return nil, false
	}
	repaired, _ := cloneJSONValue(tools).([]any)
	for i, tool := range repaired {
		repaired[i] = normalizeToolEntry(tool, &changed)
	}
	if !changed {
		return nil, false
	}
	parsed["tools"] = repaired
	sanitizeInvalidUTF8(parsed)
	return tools, true
}

// constraintView returns the request object the tool-constraint validator must
// see: parsed itself when no schema was repaired, otherwise a shallow copy of
// parsed with the caller's original tools restored, so validation judges the
// schemas the client actually sent (and refuses a client-forged normalization
// marker) without a second parse of the original bytes.
func constraintView(parsed map[string]any, originalTools []any) map[string]any {
	if originalTools == nil {
		return parsed
	}
	view := make(map[string]any, len(parsed))
	for key, value := range parsed {
		view[key] = value
	}
	view["tools"] = originalTools
	return view
}

// cloneJSONValue deep-copies a decoder-shaped value (objects, arrays, and
// immutable scalars). Non-JSON leaf types are shared, which is safe because
// the repair walk only ever rewrites map entries and array slots.
func cloneJSONValue(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for key, value := range x {
			out[key] = cloneJSONValue(value)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, value := range x {
			out[i] = cloneJSONValue(value)
		}
		return out
	default:
		return v
	}
}

// sanitizeInvalidUTF8 rewrites, in place, every string value and object key
// under v the way an encoding/json encode→decode round trip would: each
// invalid UTF-8 byte becomes U+FFFD. Valid trees are left untouched without
// allocating.
func sanitizeInvalidUTF8(v any) any {
	switch x := v.(type) {
	case string:
		if utf8.ValidString(x) {
			return x
		}
		return replaceInvalidUTF8Bytes(x)
	case []any:
		for i, value := range x {
			x[i] = sanitizeInvalidUTF8(value)
		}
		return x
	case map[string]any:
		var invalidKeys []string
		for key, value := range x {
			x[key] = sanitizeInvalidUTF8(value)
			if !utf8.ValidString(key) {
				invalidKeys = append(invalidKeys, key)
			}
		}
		for _, key := range invalidKeys {
			value := x[key]
			delete(x, key)
			x[replaceInvalidUTF8Bytes(key)] = value
		}
		return x
	default:
		return v
	}
}

// replaceInvalidUTF8Bytes substitutes U+FFFD for each invalid byte, matching
// encoding/json's per-byte � emission (not strings.ToValidUTF8, which
// collapses a run of invalid bytes into one replacement).
func replaceInvalidUTF8Bytes(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i := 0; i < len(s); {
		c, size := utf8.DecodeRuneInString(s[i:])
		if c == utf8.RuneError && size == 1 {
			b.WriteRune(utf8.RuneError)
			i++
			continue
		}
		b.WriteString(s[i : i+size])
		i += size
	}
	return b.String()
}
