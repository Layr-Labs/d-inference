package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"slices"
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

// maxToolSchemaDepth bounds how deep injectDefaultTypes recurses into a single
// tool schema (through properties / items / additionalProperties / anyOf /
// oneOf / allOf). A pathological or malicious schema nested thousands of
// levels deep could otherwise blow the Go stack or burn CPU. Real schemas are
// only a handful of levels deep, so this ceiling is unreachable in practice;
// at the limit we stop recursing and return the node UNCHANGED. Leaving a
// node deeper than this un-normalized is safe — the un-repaired part is
// bounded and astronomically rare, and the only cost is that one deep template
// render could still throw (the pre-DAR-130 status quo for that one node),
// whereas the harm we are preventing is unbounded recursion on every request.
const maxToolSchemaDepth = 64

// toolsKeyNeedle is the cheap byte gate: only bodies carrying these bytes pay
// the JSON round-trip.
var toolsKeyNeedle = []byte(`"tools"`)

// schemaUnionKeys are the JSON-Schema combinators whose members are
// themselves schemas.
var schemaUnionKeys = []string{"anyOf", "oneOf", "allOf"}

// NormalizeToolSchemas returns body with default `type`s injected into every
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
func NormalizeToolSchemas(body []byte) []byte {
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

// normalizeToolEntry rewrites one element of the "tools" array. A tool's
// JSON-Schema lives in one of three homes, detected per entry:
//
//   - Chat-completions shape: "function" is an object — its "parameters"
//     value (when the key is present) is normalized. An object "function"
//     wrapper claims the entry: a stray top-level "parameters" beside it is
//     not a recognized shape and stays untouched (never double-repair).
//   - Responses-API flat shape: no object "function" wrapper (the key is
//     absent, or holds a non-object value, which itself passes through
//     verbatim) — the top-level "parameters" value (when the key is present)
//     is normalized.
//   - Anthropic Messages shape: the "input_schema" value (when the key is
//     present) is normalized, independent of the two OpenAI homes — the
//     shapes are mutually exclusive on real traffic, but an entry carrying
//     several schema keys gets each repaired.
//
// Entries matching no shape — scalars, schema-less maps — pass through
// untouched (mirrors the Swift per-tool guard). Schema values are handed to
// injectDefaultTypes as-is: nulls and scalars come back verbatim, and keys
// are never invented on the tool entry itself. Each schema home is traversed
// from depth 0; *changed is set true if any node anywhere under it was
// repaired, which lets the caller skip the re-encode when nothing moved.
func normalizeToolEntry(tool any, changed *bool) any {
	toolDict, ok := tool.(map[string]any)
	if !ok {
		return tool
	}
	if function, ok := toolDict["function"].(map[string]any); ok {
		if parameters, ok := function["parameters"]; ok {
			function["parameters"] = injectDefaultTypes(parameters, 0, changed)
		}
	} else if parameters, ok := toolDict["parameters"]; ok {
		toolDict["parameters"] = injectDefaultTypes(parameters, 0, changed)
	}
	if inputSchema, ok := toolDict["input_schema"]; ok {
		toolDict["input_schema"] = injectDefaultTypes(inputSchema, 0, changed)
	}
	return toolDict
}

// injectDefaultTypes recursively default-fills `type` on JSON-Schema nodes. A
// node gets a type only when it looks like a schema node (has properties /
// items / additionalProperties / enum / description / anyOf / oneOf / allOf)
// — we never invent types on arbitrary maps. The inferred default favours
// structure: object when it has properties, array when it has items,
// otherwise string.
//
// depth is the current nesting level (0 at each tool schema home); *changed is
// set to true if any descendant node is repaired. At maxToolSchemaDepth we
// stop descending and return the node UNCHANGED — the only depth-bounded path,
// keeping unbounded recursion off the request hot path (see maxToolSchemaDepth).
func injectDefaultTypes(node any, depth int, changed *bool) any {
	if depth >= maxToolSchemaDepth {
		return node
	}
	switch n := node.(type) {
	case []any:
		for i, v := range n {
			n[i] = injectDefaultTypes(v, depth+1, changed)
		}
		return n
	case map[string]any:
		return injectDefaultTypesIntoSchema(n, depth, changed)
	default:
		return node
	}
}

// injectDefaultTypesIntoSchema is the map-shaped arm of injectDefaultTypes.
// Children are normalized BEFORE this node's own type is repaired — ordering
// is load-bearing: a union member declaring `"type": ["string","null"]` must
// collapse first so the parent's union inference sees a concrete string.
//
// depth/changed are threaded exactly as in injectDefaultTypes: children recurse
// at depth+1 (through injectDefaultTypes, which re-checks the depth ceiling), and
// *changed is set true the moment any node here is actually repaired (a type
// collapsed, a missing type inferred, or nullable set), so the caller can skip
// the re-encode when nothing moved.
func injectDefaultTypesIntoSchema(dict map[string]any, depth int, changed *bool) map[string]any {
	if props, ok := dict["properties"].(map[string]any); ok {
		for k, v := range props {
			props[k] = injectDefaultTypes(v, depth+1, changed)
		}
	}
	if items, ok := dict["items"]; ok {
		dict["items"] = injectDefaultTypes(items, depth+1, changed)
	}
	// additionalProperties may itself be a schema (map-shaped params, e.g.
	// {"additionalProperties":{"type":"string"}}) — recurse so its inner schema
	// gets a default type too. A bare `true`/`false` is left untouched. Routed
	// through injectDefaultTypes (not the schema arm directly) so the depth
	// ceiling bounds an additionalProperties chain too; for an in-budget map the
	// result is identical to processing it as a schema node.
	if addl, ok := dict["additionalProperties"].(map[string]any); ok {
		dict["additionalProperties"] = injectDefaultTypes(addl, depth+1, changed)
	}
	for _, key := range schemaUnionKeys {
		if variants, ok := dict[key].([]any); ok {
			for i, v := range variants {
				variants[i] = injectDefaultTypes(v, depth+1, changed)
			}
		}
	}

	// A type that is PRESENT but not a string crashes `| upper` just like a
	// missing one. The common real-world shape is the JSON-Schema array form
	// for nullable fields — `"type": ["string","null"]` — which Pydantic
	// emits for every Optional[...] tool parameter. Collapse it to a single
	// representative string (never delete the key: a node whose only content
	// is its type would not be refilled below and would crash anyway).
	// Nullability is preserved losslessly: the gemma template natively
	// renders the standard `nullable` key, so collapsing away a "null"
	// member sets it (without clobbering an explicit value).
	if t, present := dict["type"]; present {
		if _, isString := t.(string); !isString {
			members := typeStringMembers(t)
			if slices.Contains(members, "null") &&
				slices.ContainsFunc(members, func(m string) bool { return m != "null" }) {
				if _, hasNullable := dict["nullable"]; !hasNullable {
					dict["nullable"] = true
				}
			}
			dict["type"] = collapsedType(members, dict)
			*changed = true
		}
	}

	if _, present := dict["type"]; !present && looksLikeSchemaNode(dict) {
		dict["type"] = inferredType(dict)
		*changed = true
	}
	return dict
}

// typeStringMembers extracts the string members of an array-form `type`
// value. Any other shape (number, bool, object, null) yields no members,
// pushing the collapse to structural inference.
func typeStringMembers(t any) []string {
	arr, ok := t.([]any)
	if !ok {
		return nil
	}
	members := make([]string, 0, len(arr))
	for _, m := range arr {
		if s, ok := m.(string); ok {
			members = append(members, s)
		}
	}
	return members
}

// collapsedType collapses a non-string `type` value (pre-extracted string
// members of the array form) to one renderable string: the first concrete
// (non-"null") member, the lone "null" when that is all the array declares,
// else fall back to structural inference.
func collapsedType(members []string, dict map[string]any) string {
	for _, m := range members {
		if m != "null" {
			return m
		}
	}
	if len(members) > 0 {
		return members[0]
	}
	return inferredType(dict)
}

// looksLikeSchemaNode reports whether the map carries any JSON-Schema marker
// key. Only such nodes receive a defaulted `type`.
func looksLikeSchemaNode(dict map[string]any) bool {
	for _, key := range []string{
		"properties", "items", "additionalProperties",
		"enum", "description", "anyOf", "oneOf", "allOf",
	} {
		if _, ok := dict[key]; ok {
			return true
		}
	}
	return false
}

// inferredType is the structural default for a schema node's `type`: object
// when it has properties (or additionalProperties), array when it has items,
// a union member's type when it is an anyOf/oneOf/allOf (skipping "null" —
// mislabelling a union as a string would be wrong), otherwise string.
func inferredType(dict map[string]any) string {
	_, hasProps := dict["properties"]
	_, hasAddl := dict["additionalProperties"]
	if hasProps || hasAddl {
		return "object"
	}
	if _, ok := dict["items"]; ok {
		return "array"
	}
	if t, ok := unionMemberType(dict); ok {
		return t
	}
	return "string"
}

// unionMemberType derives a representative `type` for a union node from the
// first member that declares a concrete, non-"null" type. The second return
// is false when none is found.
func unionMemberType(dict map[string]any) (string, bool) {
	for _, key := range schemaUnionKeys {
		variants, ok := dict[key].([]any)
		if !ok {
			continue
		}
		for _, variant := range variants {
			v, ok := variant.(map[string]any)
			if !ok {
				continue
			}
			if t, ok := v["type"].(string); ok && t != "null" {
				return t, true
			}
		}
	}
	return "", false
}
