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
// Byte-identity with the bytes path holds because encoding/json's decoder
// already produces a well-formed tree — it coerces invalid UTF-8 in strings
// and keys to U+FFFD while unquoting — so the repaired map serializes to
// exactly what decoding the bytes path's re-encoded output would have
// produced. The gates are the same two the bytes path applies, measured on
// the caller's input.

import "bytes"

// normalizeParsedToolSchemas repairs the tool JSON-Schemas of an already
// decoded request in place, with the same gates as NormalizeToolSchemas,
// measured against rawBody (the caller's input bytes): bodies over
// maxToolNormalizationBytes, bodies without the literal `"tools"` key bytes
// (an escaped spelling of the key is forwarded verbatim, exactly as the bytes
// path always did), and bodies whose "tools" is not an array are left
// untouched. When a repair was made it returns the caller's original tools
// value (never mutated) and changed=true; otherwise (nil, false) and parsed is
// exactly as it was.
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
