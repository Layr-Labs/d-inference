package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"slices"
	"strings"
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

const originalBooleanSchemaKey = "x-darkbloom-original-boolean-schema"

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

// injectDefaultTypes recursively default-fills `type` on JSON-Schema nodes,
// starting from a tool's schema home (a NON-positional root: a bare `{}`
// parameters object stays `{}`, and a type is only invented when the map
// carries a schema marker key — see looksLikeSchemaNode). The inferred
// default favours structure: object when it has properties, array when it
// has items, otherwise string.
//
// depth is the current nesting level (0 at each tool schema home); *changed is
// set to true if any descendant node is repaired. At maxToolSchemaDepth we
// stop descending and return the node UNCHANGED — the only depth-bounded path,
// keeping unbounded recursion off the request hot path (see maxToolSchemaDepth).
func injectDefaultTypes(node any, depth int, changed *bool) any {
	return injectTypes(node, depth, changed, false)
}

// injectTypes is the traversal core behind injectDefaultTypes. positional
// reports whether node sits in a SCHEMA-POSITIONAL slot — a value under
// `properties`/`patternProperties`, `items` (including tuple-form members),
// `prefixItems`, a map-valued `additionalProperties`, or a member of
// `anyOf`/`oneOf`/`allOf`. JSON Schema defines every value in those slots to
// BE a schema, so a positional value needs no marker-key evidence:
//
//   - a boolean (the valid JSON-Schema allow/deny-all shorthand, e.g.
//     `"x": true` under properties) is replaced with a render-safe string
//     schema carrying originalBooleanSchemaKey, so Gemma can subscript
//     `value['type']` while provider-side auto validation retains the original
//     allow/deny-all semantics;
//   - a map is guaranteed a string `type` after recursion (missing →
//     inferredType; present-but-non-string → collapsed, see the schema arm),
//     with NO looksLikeSchemaNode gate — that heuristic previously let valid
//     marker-less schemas (`{}`, const-/default-/$ref-/format-only nodes)
//     through to crash the template's `| upper`;
//   - arrays keep positionality for their members (tuple-form `items`,
//     `prefixItems`, union member lists).
//
// Non-positional maps (the tool schema roots) keep the marker-key heuristic:
// we still never invent types on arbitrary caller maps.
func injectTypes(node any, depth int, changed *bool, positional bool) any {
	if depth >= maxToolSchemaDepth {
		return node
	}
	switch n := node.(type) {
	case bool:
		if positional {
			*changed = true
			return map[string]any{
				"type":                   "string",
				originalBooleanSchemaKey: n,
			}
		}
		return node
	case []any:
		for i, v := range n {
			n[i] = injectTypes(v, depth+1, changed, positional)
		}
		return n
	case map[string]any:
		return injectDefaultTypesIntoSchema(n, depth, changed, positional)
	default:
		return node
	}
}

// injectDefaultTypesIntoSchema is the map-shaped arm of injectTypes.
// Children are normalized BEFORE this node's own type is repaired — ordering
// is load-bearing: a union member declaring `"type": ["string","null"]` must
// collapse first so the parent's union inference sees a concrete string.
//
// depth/changed are threaded exactly as in injectTypes: children recurse at
// depth+1 (through injectTypes, which re-checks the depth ceiling), and
// *changed is set true the moment any node here is actually repaired (a type
// collapsed, a missing type inferred, nullable set, or a boolean/typeless
// positional child rewritten), so the caller can skip the re-encode when
// nothing moved. positional is this NODE's own slot kind (see injectTypes);
// values under the schema-container keys below are always positional.
func injectDefaultTypesIntoSchema(dict map[string]any, depth int, changed *bool, positional bool) map[string]any {
	// An EMPTY positional map is the `{}` "anything" schema — semantically
	// identical to the boolean `true` schema, so it gets the same render-safe
	// rewrite: a string type for the template plus the original-boolean-schema
	// marker so provider-side auto validation restores allow-all semantics
	// instead of enforcing the synthetic string type.
	if positional && len(dict) == 0 {
		*changed = true
		return map[string]any{
			"type":                   "string",
			originalBooleanSchemaKey: true,
		}
	}
	for _, key := range []string{"properties", "patternProperties"} {
		if props, ok := dict[key].(map[string]any); ok {
			for k, v := range props {
				props[k] = injectTypes(v, depth+1, changed, true)
			}
		}
	}
	if items, ok := dict["items"]; ok {
		dict["items"] = injectTypes(items, depth+1, changed, true)
	}
	if prefix, ok := dict["prefixItems"].([]any); ok {
		for i, v := range prefix {
			prefix[i] = injectTypes(v, depth+1, changed, true)
		}
	}
	// additionalProperties may itself be a schema (map-shaped params, e.g.
	// {"additionalProperties":{"type":"string"}}) — recurse so its inner schema
	// gets a default type too. A bare `true`/`false` is left untouched here (it
	// is the standard allow/deny-all switch, is never subscripted by the
	// templates, and rewriting it would change validation semantics for no
	// render gain) — only the MAP-valued form is schema-positional. Routed
	// through injectTypes so the depth ceiling bounds an additionalProperties
	// chain too.
	if addl, ok := dict["additionalProperties"].(map[string]any); ok {
		dict["additionalProperties"] = injectTypes(addl, depth+1, changed, true)
	}
	for _, key := range schemaUnionKeys {
		if variants, ok := dict[key].([]any); ok {
			for i, v := range variants {
				variants[i] = injectTypes(v, depth+1, changed, true)
			}
		}
	}
	if dict["type"] == nil && nullableCombinatorUnion(dict) {
		if nullable, _ := dict["nullable"].(bool); !nullable {
			dict["nullable"] = true
			*changed = true
		}
	}
	// A typeless node whose const/enum admits null beside a concrete value
	// (e.g. `{"enum":[1,null]}`) keeps null validity through the standard
	// `nullable` key, exactly like the array-form type collapse below —
	// the injected concrete type alone would reject a schema-valid null.
	if dict["type"] == nil {
		if concrete, sawNull, ok := finiteValueTypes(dict); ok && sawNull && len(concrete) > 0 {
			if nullable, _ := dict["nullable"].(bool); !nullable {
				dict["nullable"] = true
				*changed = true
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
	// member sets it to true. An explicit false cannot override the union's
	// null member without changing the original schema semantics.
	if t, present := dict["type"]; present {
		if _, isString := t.(string); !isString {
			members := typeStringMembers(t)
			if slices.Contains(members, "null") &&
				slices.ContainsFunc(members, func(m string) bool { return m != "null" }) {
				if nullable, _ := dict["nullable"].(bool); !nullable {
					dict["nullable"] = true
				}
			}
			dict["type"] = collapsedType(members, dict)
			*changed = true
		}
	}

	// A positional node IS a schema by definition, so a missing type is always
	// filled; a non-positional map (a tool schema root) still needs marker-key
	// evidence before we invent one.
	if _, present := dict["type"]; !present && (positional || looksLikeSchemaNode(dict)) {
		dict["type"] = inferredType(dict)
		*changed = true
	}

	// An OBJECT-typed schema node must carry a mapping `properties`. The served
	// Gemma template's OBJECT branch otherwise falls into its
	// `{%- elif value is mapping -%}` fallback (filter_keys=true), which
	// iterates the node's OWN keys — `patternProperties`, `$defs`, any junk —
	// as if each were a property schema; those containers carry no `type`, so
	// `value['type'] | upper` throws the exact render error this normalizer
	// exists to prevent. Mirrors the Swift twin (ToolSchemaNormalization) and
	// gemma4 enforcement invariant 4: a missing OR non-mapping `properties` on
	// an object-typed node becomes an empty map. Render-neutral for templates
	// that guard on `properties` truthiness (an empty dict is falsy in Jinja),
	// and runs AFTER type resolution so inferred-object nodes (e.g. a typeless
	// patternProperties-only schema) are covered too.
	if t, _ := dict["type"].(string); strings.EqualFold(t, "object") {
		if _, isMap := dict["properties"].(map[string]any); !isMap {
			dict["properties"] = map[string]any{}
			*changed = true
		}
	}
	return dict
}

func nullableCombinatorUnion(dict map[string]any) bool {
	for _, key := range []string{"anyOf", "oneOf"} {
		variants, ok := dict[key].([]any)
		if !ok {
			continue
		}
		hasNull := false
		hasConcrete := false
		for _, rawVariant := range variants {
			variant, ok := rawVariant.(map[string]any)
			if !ok {
				continue
			}
			if nullable, _ := variant["nullable"].(bool); nullable {
				hasNull = true
			}
			switch member := variant["type"].(type) {
			case string:
				if strings.EqualFold(member, "null") {
					hasNull = true
				} else {
					hasConcrete = true
				}
			case []any:
				for _, rawType := range member {
					if member, ok := rawType.(string); ok {
						if strings.EqualFold(member, "null") {
							hasNull = true
						} else {
							hasConcrete = true
						}
					}
				}
			}
		}
		if hasNull && hasConcrete {
			return true
		}
	}
	return false
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
			members = append(members, strings.ToLower(s))
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
// key. Only NON-positional nodes (the tool schema roots) need this evidence
// to receive a defaulted `type` — schema-positional values are schemas by
// definition (see injectTypes).
func looksLikeSchemaNode(dict map[string]any) bool {
	for _, key := range []string{
		"properties", "patternProperties", "items", "prefixItems",
		"additionalProperties", "enum", "description", "anyOf", "oneOf", "allOf",
	} {
		if _, ok := dict[key]; ok {
			return true
		}
	}
	return false
}

// inferredType is the structural default for a schema node's `type`: object
// when it has properties / patternProperties / additionalProperties, array
// when it has items / prefixItems, a union member's type when it is an
// anyOf/oneOf/allOf (skipping "null" — mislabelling a union as a string would
// be wrong), the single concrete type of its const/enum values when the node
// declares finite values (a typeless `{"const":1}` accepts 1, so the injected
// render type must be "number", not "string" — the string default would make
// every schema-valid emission fail post-generation validation), otherwise
// string.
func inferredType(dict map[string]any) string {
	for _, key := range []string{"properties", "patternProperties", "additionalProperties"} {
		if _, ok := dict[key]; ok {
			return "object"
		}
	}
	for _, key := range []string{"items", "prefixItems"} {
		if _, ok := dict[key]; ok {
			return "array"
		}
	}
	if t, ok := unionMemberType(dict); ok {
		return t
	}
	if concrete, sawNull, ok := finiteValueTypes(dict); ok {
		if len(concrete) == 1 {
			for name := range concrete {
				return name
			}
		}
		if len(concrete) == 0 && sawNull {
			return "null"
		}
	}
	if families := assertionFamilyTypes(dict); len(families) == 1 {
		for family := range families {
			return family
		}
	}
	return "string"
}

// assertionFamilyByKeyword maps type-scoped JSON-Schema assertion keywords to
// the instance type they constrain. A typeless `{"minimum":5}` accepts 6, so
// the injected render type must be "number" — the string default would make
// every schema-valid numeric emission fail post-generation validation.
var assertionFamilyByKeyword = map[string]string{
	"minimum":          "number",
	"maximum":          "number",
	"exclusiveMinimum": "number",
	"exclusiveMaximum": "number",
	"multipleOf":       "number",
	"minLength":        "string",
	"maxLength":        "string",
	"pattern":          "string",
	"minItems":         "array",
	"maxItems":         "array",
	"uniqueItems":      "array",
	"contains":         "array",
	"minContains":      "array",
	"maxContains":      "array",
	"minProperties":    "object",
	"maxProperties":    "object",
	"required":         "object",
}

// assertionFamilyTypes reports the instance-type families implied by a node's
// type-scoped assertion keywords.
func assertionFamilyTypes(dict map[string]any) map[string]struct{} {
	families := make(map[string]struct{}, 2)
	for keyword, family := range assertionFamilyByKeyword {
		if _, ok := dict[keyword]; ok {
			families[family] = struct{}{}
		}
	}
	return families
}

// typelessAssertionFamiliesAmbiguous reports whether a typeless node's
// assertions cannot determine a single renderable type: either its assertion
// keywords span more than one type family (e.g. `{"minimum":5,"minLength":2}`)
// or its only assertion is `not` (e.g. `{"not":{"type":"string"}}`, which
// accepts every non-string — no injected type can preserve that, and the
// string default would make the schema unsatisfiable). Callers reject these
// before normalization; nodes with structural, union, or finite-value
// evidence are typed by those higher-priority rules instead.
func typelessAssertionFamiliesAmbiguous(dict map[string]any) bool {
	for _, key := range []string{
		"properties", "patternProperties", "additionalProperties",
		"items", "prefixItems",
	} {
		if _, ok := dict[key]; ok {
			return false
		}
	}
	if _, ok := unionMemberType(dict); ok {
		return false
	}
	families := assertionFamilyTypes(dict)
	if len(families) > 1 {
		return true
	}
	if _, negated := dict["not"]; negated && len(families) == 0 {
		return true
	}
	return false
}

// finiteValueTypes reports the JSON type names of a node's const/enum values:
// the set of concrete (non-null) member types plus whether null appears.
// ok is false when the node carries no const and no non-empty enum array.
func finiteValueTypes(dict map[string]any) (concrete map[string]struct{}, sawNull bool, ok bool) {
	var values []any
	if constant, present := dict["const"]; present {
		values = []any{constant}
	} else if members, isArray := dict["enum"].([]any); isArray && len(members) > 0 {
		values = members
	} else {
		return nil, false, false
	}
	concrete = make(map[string]struct{}, 2)
	for _, value := range values {
		name := jsonValueTypeName(value)
		if name == "null" {
			sawNull = true
			continue
		}
		concrete[name] = struct{}{}
	}
	return concrete, sawNull, true
}

// jsonValueTypeName maps a decoded JSON value to its JSON-Schema type name.
// Integral and fractional numbers both report "number" — "number" admits
// integers under raw validation, so the coarser name is always safe.
func jsonValueTypeName(value any) string {
	switch value.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case json.Number, float64:
		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "string"
	}
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
