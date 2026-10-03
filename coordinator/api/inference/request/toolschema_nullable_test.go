package request

import (
	"testing"
)

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
