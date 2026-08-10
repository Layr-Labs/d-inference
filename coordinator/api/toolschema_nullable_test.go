package api

import (
	"testing"
)

// Swift: collapsesNullableArrayTypeToConcreteMember
func TestNormalizeToolSchemas_CollapsesNullableArrayTypeToConcreteMember(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"get_weather",
	  "parameters":{"type":"object","properties":{
	    "city":{"type":["string","null"],"description":"city"}},
	    "required":["city"]}}}]}`)

	out := NormalizeToolSchemas(body)
	city := tsnMap(t, tsnProps(t, out)["city"], "city")
	if got := tsnType(t, city, "city"); got != "string" {
		t.Errorf("city type = %q, want string", got)
	}
	// Nullability preserved losslessly via the template-supported key.
	if city["nullable"] != true {
		t.Errorf("city nullable = %v, want true", city["nullable"])
	}
	// The nullable pair has ONE concrete member — no union to preserve, so no
	// anyOf is synthesized (the parity corpus pins this byte shape).
	if _, ok := city["anyOf"]; ok {
		t.Errorf("city anyOf = %v, want absent for single-concrete pair", city["anyOf"])
	}
	if req, ok := tsnParams(t, out)["required"].([]any); !ok || len(req) != 1 || req[0] != "city" {
		t.Errorf("required = %v, want [city]", tsnParams(t, out)["required"])
	}
}

// Swift: collapsesArrayTypeSkippingLeadingNull
func TestNormalizeToolSchemas_CollapsesArrayTypeSkippingLeadingNull(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "n":{"type":["null","integer"]}}}}}]}`)

	n := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["n"], "n")
	if got := tsnType(t, n, "n"); got != "integer" {
		t.Errorf("n type = %q, want integer", got)
	}
	if n["nullable"] != true {
		t.Errorf("n nullable = %v, want true", n["nullable"])
	}
}

// Swift: collapsesNullOnlyArrayTypeToNullString
func TestNormalizeToolSchemas_CollapsesNullOnlyArrayTypeToNullString(t *testing.T) {
	// ["null"] has no concrete member — keep the honest "null", which still
	// renders (it is a string for `| upper`).
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "x":{"type":["null"]}}}}}]}`)

	x := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["x"], "x")
	if got := tsnType(t, x, "x"); got != "null" {
		t.Errorf("x type = %q, want null", got)
	}
	// No concrete member was collapsed away, so nullable is NOT synthesized.
	if _, ok := x["nullable"]; ok {
		t.Errorf("x nullable = %v, want absent", x["nullable"])
	}
}

// Swift: collapsesArrayTypeInNestedObjectAndItems
func TestNormalizeToolSchemas_CollapsesArrayTypeInNestedObjectAndItems(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"set_alarm",
	  "parameters":{"type":"object","properties":{
	    "opts":{"type":"object","properties":{"snooze":{"type":["integer","null"]}}},
	    "tags":{"type":"array","items":{"type":["string","null"]}}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	snooze := tsnMap(t, tsnMap(t, tsnMap(t, props["opts"], "opts")["properties"], "opts.properties")["snooze"], "snooze")
	if got := tsnType(t, snooze, "snooze"); got != "integer" {
		t.Errorf("snooze type = %q, want integer", got)
	}
	if snooze["nullable"] != true {
		t.Errorf("snooze nullable = %v, want true", snooze["nullable"])
	}
	items := tsnMap(t, tsnMap(t, props["tags"], "tags")["items"], "tags.items")
	if got := tsnType(t, items, "tags.items"); got != "string" {
		t.Errorf("items type = %q, want string", got)
	}
	if items["nullable"] != true {
		t.Errorf("items nullable = %v, want true", items["nullable"])
	}
}

// Swift: malformedNonStringTypeFallsBackToStructuralInference
func TestNormalizeToolSchemas_MalformedNonStringTypeFallsBackToStructuralInference(t *testing.T) {
	// A numeric `type` is invalid JSON Schema; repair it from structure
	// (properties present → object) instead of leaving the list/number for
	// the template to choke on.
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "cfg":{"type":42,"properties":{"k":{"type":"string"}}},
	    "v":{"type":7,"description":"v"}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	cfg := tsnMap(t, props["cfg"], "cfg")
	if got := tsnType(t, cfg, "cfg"); got != "object" {
		t.Errorf("cfg type = %q, want object", got)
	}
	v := tsnMap(t, props["v"], "v")
	if got := tsnType(t, v, "v"); got != "string" {
		t.Errorf("v type = %q, want string", got)
	}
	// No "null" member was collapsed, so nullable is not synthesized.
	for name, node := range map[string]map[string]any{"cfg": cfg, "v": v} {
		if _, ok := node["nullable"]; ok {
			t.Errorf("%s nullable = %v, want absent", name, node["nullable"])
		}
	}
}

// Swift: unionMemberWithArrayTypeStillDrivesParentInference
func TestNormalizeToolSchemas_UnionMemberWithArrayTypeStillDrivesParentInference(t *testing.T) {
	// Ordering is load-bearing: members collapse BEFORE the parent's union
	// inference, so a first member declaring ["string","null"] must yield a
	// "string" parent type (not fall through to the default).
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "u":{"anyOf":[{"type":["string","null"]},{"type":"integer"}],"description":"u"}}}}}]}`)

	u := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["u"], "u")
	if got := tsnType(t, u, "u"); got != "string" {
		t.Errorf("u type = %q, want string", got)
	}
	variants, ok := u["anyOf"].([]any)
	if !ok || len(variants) != 2 {
		t.Fatalf("anyOf = %v, want 2 members", u["anyOf"])
	}
	first := tsnMap(t, variants[0], "anyOf[0]")
	if got := tsnType(t, first, "anyOf[0]"); got != "string" {
		t.Errorf("anyOf[0] type = %q, want string (collapsed before parent inference)", got)
	}
	if first["nullable"] != true {
		t.Errorf("anyOf[0] nullable = %v, want true", first["nullable"])
	}
}

// Swift: collapsesArrayTypeOnTopLevelParametersNode
func TestNormalizeToolSchemas_CollapsesArrayTypeOnTopLevelParametersNode(t *testing.T) {
	// The template also renders params['type'] | upper at the top level.
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":["object","null"],"properties":{"q":{"type":"string"}}}}}]}`)

	params := tsnParams(t, NormalizeToolSchemas(body))
	if got := tsnType(t, params, "parameters"); got != "object" {
		t.Errorf("parameters type = %q, want object", got)
	}
	if params["nullable"] != true {
		t.Errorf("parameters nullable = %v, want true", params["nullable"])
	}
}

// Swift: collapsesArrayTypeInsideAdditionalPropertiesSchema
func TestNormalizeToolSchemas_CollapsesArrayTypeInsideAdditionalPropertiesSchema(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "kv":{"type":"object","additionalProperties":{"type":["number","null"]}}}}}}]}`)

	kv := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["kv"], "kv")
	addl := tsnMap(t, kv["additionalProperties"], "kv.additionalProperties")
	if got := tsnType(t, addl, "additionalProperties"); got != "number" {
		t.Errorf("additionalProperties type = %q, want number", got)
	}
	if addl["nullable"] != true {
		t.Errorf("additionalProperties nullable = %v, want true", addl["nullable"])
	}
}

// An explicit false cannot erase a null member from the original type union.
func TestNormalizeToolSchemas_TypeUnionOverridesNullableFalse(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "kept":{"type":["STRING","NULL"],"nullable":false},
	    "set":{"type":["string","null"]}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	kept := tsnMap(t, props["kept"], "kept")
	if got := tsnType(t, kept, "kept"); got != "string" {
		t.Errorf("kept type = %q, want string", got)
	}
	if kept["nullable"] != true {
		t.Errorf("kept nullable = %v, want union-preserving true", kept["nullable"])
	}
	set := tsnMap(t, props["set"], "set")
	if set["nullable"] != true {
		t.Errorf("set nullable = %v, want synthesized true", set["nullable"])
	}
}

func TestNormalizeToolSchemas_CombinatorUnionPreservesNullability(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "value":{"anyOf":[{"type":"string"},{"type":"null"}]},
	    "explicit":{"type":"string","anyOf":[{"type":"string"},{"type":"null"}]}
	  }}}}]}`)
	properties := tsnProps(t, NormalizeToolSchemas(body))
	value := tsnMap(t, properties["value"], "value")
	if got := tsnType(t, value, "value"); got != "string" {
		t.Fatalf("value type = %q, want string", got)
	}
	if value["nullable"] != true {
		t.Fatalf("value nullable = %v, want true", value["nullable"])
	}
	explicit := tsnMap(t, properties["explicit"], "explicit")
	if explicit["nullable"] != nil {
		t.Fatalf("explicit parent type was widened: nullable = %v", explicit["nullable"])
	}
}

func TestNormalizeToolSchemas_PreservesBooleanSchemaSemantics(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"allow":true,"deny":false}}}}]}`)
	properties := tsnProps(t, NormalizeToolSchemas(body))
	for name, want := range map[string]bool{"allow": true, "deny": false} {
		schema := tsnMap(t, properties[name], name)
		if got := tsnType(t, schema, name); got != "string" {
			t.Fatalf("%s type = %q, want render-safe string", name, got)
		}
		if got, ok := schema[originalBooleanSchemaKey].(bool); !ok || got != want {
			t.Fatalf("%s marker = %#v, want %v", name, schema[originalBooleanSchemaKey], want)
		}
	}
}

// tsnAnyOfTypes asserts the node's anyOf is a list of bare {"type": ...}
// members and returns the member types in order.
func tsnAnyOfTypes(t *testing.T, node map[string]any, what string) []string {
	t.Helper()
	variants, ok := node["anyOf"].([]any)
	if !ok {
		t.Fatalf("%s anyOf = %#v, want array", what, node["anyOf"])
	}
	types := make([]string, 0, len(variants))
	for i, v := range variants {
		member := tsnMap(t, v, what+".anyOf member")
		if len(member) != 1 {
			t.Fatalf("%s anyOf[%d] = %v, want bare type-only schema", what, i, member)
		}
		types = append(types, tsnType(t, member, what+".anyOf member"))
	}
	return types
}

// Swift: multiConcreteTypeArrayPreservedViaAnyOf
func TestNormalizeToolSchemas_MultiConcreteTypeArrayPreservedViaAnyOf(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "id":{"type":["string","integer"]}}}}}]}`)

	id := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["id"], "id")
	if got := tsnType(t, id, "id"); got != "string" {
		t.Errorf("id type = %q, want first concrete member string", got)
	}
	if got := tsnAnyOfTypes(t, id, "id"); len(got) != 2 || got[0] != "string" || got[1] != "integer" {
		t.Errorf("id anyOf types = %v, want [string integer]", got)
	}
	if _, ok := id["nullable"]; ok {
		t.Errorf("id nullable = %v, want absent without a null member", id["nullable"])
	}
}

// Swift: multiConcreteNullableTypeArrayKeepsNullAndUnion
func TestNormalizeToolSchemas_MultiConcreteNullableTypeArrayKeepsNullAndUnion(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "id":{"type":["integer","string","null"]}}}}}]}`)

	id := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["id"], "id")
	if got := tsnType(t, id, "id"); got != "integer" {
		t.Errorf("id type = %q, want first concrete member integer", got)
	}
	if id["nullable"] != true {
		t.Errorf("id nullable = %v, want true", id["nullable"])
	}
	// The null member rides the nullable side-channel, never the union.
	if got := tsnAnyOfTypes(t, id, "id"); len(got) != 2 || got[0] != "integer" || got[1] != "string" {
		t.Errorf("id anyOf types = %v, want [integer string]", got)
	}
}

// Swift: multiConcreteTypeArrayWithExistingCombinatorCollapsesOnly
func TestNormalizeToolSchemas_MultiConcreteTypeArrayWithExistingCombinatorCollapsesOnly(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "v":{"type":["string","integer"],"anyOf":[{"minLength":1}]},
	    "w":{"type":["string","integer"],"allOf":[{"minLength":1}]}}}}}]}`)

	props := tsnProps(t, NormalizeToolSchemas(body))
	v := tsnMap(t, props["v"], "v")
	if got := tsnType(t, v, "v"); got != "string" {
		t.Errorf("v type = %q, want string", got)
	}
	// The author's combinator keeps its written semantics: no second union is
	// layered on, and the existing member survives (type-injected only).
	variants, ok := v["anyOf"].([]any)
	if !ok || len(variants) != 1 {
		t.Fatalf("v anyOf = %#v, want the single authored member", v["anyOf"])
	}
	if member := tsnMap(t, variants[0], "v.anyOf[0]"); member["minLength"] == nil {
		t.Errorf("v anyOf[0] = %v, want the authored minLength member", member)
	}
	w := tsnMap(t, props["w"], "w")
	if _, ok := w["anyOf"]; ok {
		t.Errorf("w anyOf = %v, want absent beside authored allOf", w["anyOf"])
	}
}

// Swift: duplicateTypeMembersDedupedCaseInsensitively
func TestNormalizeToolSchemas_DuplicateTypeMembersDedupedCaseInsensitively(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{
	    "id":{"type":["string","STRING","integer"]}}}}}]}`)

	id := tsnMap(t, tsnProps(t, NormalizeToolSchemas(body))["id"], "id")
	if got := tsnType(t, id, "id"); got != "string" {
		t.Errorf("id type = %q, want string", got)
	}
	if got := tsnAnyOfTypes(t, id, "id"); len(got) != 2 || got[0] != "string" || got[1] != "integer" {
		t.Errorf("id anyOf types = %v, want deduped [string integer]", got)
	}
}
