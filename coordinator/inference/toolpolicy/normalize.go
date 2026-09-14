package toolpolicy

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// Tool-schema normalization (DAR-130), a Go port of the Swift provider's
// ToolSchemaNormalization.ensureParameterTypes
// (provider-swift/Sources/ProviderCore/Inference/ToolSchemaNormalization.swift).
// The per-schema repair semantics (injectDefaultTypes and helpers) must stay
// semantically in sync with the Swift implementation.
//
// Gemma-style chat templates render `{{ value['type'] | upper }}` over each
// tool parameter. A `type` that is missing — a legitimate OpenAI shape (e.g.
// an enum-only or anyOf property) — or present but not a string (the
// JSON-Schema nullable idiom `"type": ["string","null"]` that Pydantic emits
// for every Optional[...] field) makes the Jinja `| upper` filter throw,
// surfacing to the consumer as a 500. Providers normalize since 0.6.3, but
// the fleet updates slowly; normalizing centrally protects consumers from
// lagging providers the moment the coordinator deploys.
//
// Three wire shapes put a JSON-Schema on a tool entry, all of which reach the
// same templates (the same DAR-130 incident class), so all three are repaired
// (per-entry detection rules in normalizeToolEntry):
//
//  1. OpenAI chat completions: tools[].function.parameters — the original
//     shape, and the only one the Swift provider-side normalizer covers as
//     of 0.6.4.
//  2. OpenAI Responses API (flat): tools[].parameters with no "function"
//     wrapper. The coordinator converts Responses→chat AFTER this
//     normalization runs and copies parameters verbatim, so repairing the
//     flat shape pre-conversion fixes that path end-to-end.
//  3. Anthropic Messages: tools[].input_schema, served via /v1/messages.
//
// Because the provider-side normalizer covers only shape 1, this
// coordinator-side breadth is the fleet's only protection for shapes 2 and 3.

// maxToolNormalizationBytes is the upper bound on the body we'll JSON
// round-trip for tool-schema normalization. Tool definitions are tiny (KB),
// so a multi-MB body — e.g. a long prompt that merely contains the word
// "tools" — should not trigger a full parse + recursive traversal. Above this
// we skip normalization, bounding the cost on the (already size-capped)
// inference path.
const maxToolNormalizationBytes = 4 * 1024 * 1024

// toolsKeyNeedle is the cheap byte gate: only bodies carrying these bytes pay
// the JSON round-trip.
var toolsKeyNeedle = []byte(`"tools"`)

// NormalizeBytes returns body with default `type`s injected into every
// JSON-Schema node under each tool's schema home — function.parameters (chat
// completions), top-level parameters (Responses flat shape), or input_schema
// (Anthropic Messages) — so chat templates always have a string to
// upper-case.
//
// Fast-paths out (returns the input unchanged) when the body exceeds
// maxToolNormalizationBytes, carries no "tools" bytes, isn't a JSON object,
// or its "tools" value isn't an array. On ANY error path the input is
// returned unchanged — this function must never break a request that would
// otherwise work.
//
// The body is decoded with json.Decoder.UseNumber so numbers round-trip
// verbatim (no float64 mangling of int64s or high-precision decimals). When a
// repair IS made the body is re-marshalled, which reorders keys and normalizes
// whitespace; every field other than "tools" survives value-equivalent. When
// no tool needed a repair (the common case — modern clients and providers
// already emit valid types) the ORIGINAL body bytes are returned verbatim: a
// "changed" signal is threaded out of the recursion so we skip the re-encode
// entirely, both saving the work and preserving the caller's exact bytes.
func NormalizeBytes(body []byte) []byte {
	// Bound the work: skip the round-trip for oversized bodies (see the constant).
	if len(body) > maxToolNormalizationBytes {
		return body
	}
	// Cheap gate: only pay the JSON round-trip for requests that carry tools.
	if !bytes.Contains(body, toolsKeyNeedle) {
		return body
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var decoded any
	if err := dec.Decode(&decoded); err != nil {
		return body
	}
	// Trailing content after the JSON document means the body isn't a single
	// well-formed object (Swift's JSONSerialization rejects it too) — leave it
	// for downstream validation to handle.
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return body
	}
	root, ok := decoded.(map[string]any)
	if !ok {
		return body
	}
	tools, ok := root["tools"].([]any)
	if !ok {
		return body
	}
	changed := false
	for i, tool := range tools {
		tools[i] = normalizeToolEntry(tool, &changed)
	}
	// Nothing was injected or collapsed across any tool: return the caller's
	// original bytes untouched rather than re-encoding (which would needlessly
	// reorder keys and normalize whitespace for no semantic gain).
	if !changed {
		return body
	}

	var buf bytes.Buffer
	buf.Grow(len(body))
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(root); err != nil {
		return body
	}
	// Encoder appends a newline after the document; the input had none.
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'})
}

// NormalizeParsed repairs the tool JSON-Schemas of an already
// decoded request in place, with the same gates as NormalizeBytes,
// measured against rawBody (the caller's input bytes): bodies over
// maxToolNormalizationBytes, bodies without the literal `"tools"` key bytes
// (an escaped spelling of the key is forwarded verbatim, exactly as the bytes
// path always did), and bodies whose "tools" is not an array are left
// untouched. When a repair was made it returns the caller's original tools
// value (never mutated) and changed=true; otherwise (nil, false) and parsed is
// exactly as it was.
func NormalizeParsed(parsed map[string]any, rawBody []byte) (originalTools []any, changed bool) {
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
