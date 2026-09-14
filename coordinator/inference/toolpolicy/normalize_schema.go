package toolpolicy

import (
	"slices"
	"strings"
)

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
	// Boolean/empty schemas inside combinators are rewritten to render
	// markers above. Fold combinators whose result is therefore constant
	// before inferring a parent type; otherwise `allOf:[{}]` inherits the
	// marker's synthetic string type and stops accepting numbers/objects.
	// The fold is exact for the boolean identities below and retains
	// annotation-only siblings.
	if positional {
		if accepts, annotations, ok := constantMarkedCombinator(dict); ok {
			clear(dict)
			dict["type"] = "string"
			dict[originalBooleanSchemaKey] = accepts
			for key, value := range annotations {
				dict[key] = value
			}
			*changed = true
			return dict
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
			// A multi-concrete array (`["string","integer"]`) declares a real
			// union the single render type cannot carry: the render pipeline
			// needs one `value['type'] | upper` string, but the provider's
			// post-generation validator enforces what is on the wire, so
			// keeping only the first member would reject schema-valid
			// emissions of every other branch. JSON Schema defines the array
			// form as exactly an anyOf of its single types, so the surviving
			// concrete members are mirrored into `anyOf` — that survives the
			// wire, and the validator prefers union branches over the sibling
			// render type. A node that already carries a combinator keeps the
			// conjunctive semantics its author wrote (layering a second union
			// would change them); that pathological shape stays knowingly
			// narrowed to the first member. Mirrors: null member → `nullable`
			// (above), concrete members → `anyOf` (here).
			if concrete := distinctConcreteTypeMembers(members); len(concrete) >= 2 &&
				!hasSchemaUnionKey(dict) {
				union := make([]any, len(concrete))
				for i, m := range concrete {
					union[i] = map[string]any{"type": m}
				}
				dict["anyOf"] = union
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
