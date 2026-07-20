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
