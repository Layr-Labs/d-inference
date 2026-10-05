package request

import (
	"bytes"

	jsonvalue "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"
)

// normalizeParsedToolSchemas repairs the tool JSON-Schemas of an already
// decoded request in place, with the same gates as NormalizeToolSchemas,
// measured against rawBody (the caller's input bytes): bodies over
// maxToolNormalizationBytes, bodies without the literal `"tools"` key bytes
// (an escaped spelling of the key is forwarded verbatim, exactly as the bytes
// path always did), and bodies whose "tools" is not an array are left
// untouched. When a repair was made it returns the caller's original tools
// value (never mutated) and changed=true; otherwise (nil, false) and parsed is
// exactly as it was.
func NormalizeParsedToolSchemas(parsed map[string]any, rawBody []byte) (originalTools []any, changed bool) {
	if len(rawBody) > maxToolNormalizationBytes || !bytes.Contains(rawBody, toolsKeyNeedle) {
		return nil, false
	}
	tools, ok := parsed["tools"].([]any)
	if !ok {
		return nil, false
	}
	repaired, _ := jsonvalue.Clone(tools).([]any)
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
func ConstraintView(parsed map[string]any, originalTools []any) map[string]any {
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
