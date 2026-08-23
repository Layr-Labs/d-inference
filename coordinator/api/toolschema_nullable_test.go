package api

import (
	"testing"
)

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
