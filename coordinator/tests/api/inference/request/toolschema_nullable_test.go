package request_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"

	toolpolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/toolpolicy"
)

func TestNormalizeToolSchemas_PreservesBooleanSchemaSemantics(t *testing.T) {
	body := []byte(`{"tools":[{"type":"function","function":{"name":"f",
	  "parameters":{"type":"object","properties":{"allow":true,"deny":false}}}}]}`)
	properties := tsnProps(t, production.NormalizeToolSchemas(body))
	for name, want := range map[string]bool{"allow": true, "deny": false} {
		schema := tsnMap(t, properties[name], name)
		if got := tsnType(t, schema, name); got != "string" {
			t.Fatalf("%s type = %q, want render-safe string", name, got)
		}
		if got, ok := schema[toolpolicy.OriginalBooleanSchemaKey].(bool); !ok || got != want {
			t.Fatalf("%s marker = %#v, want %v", name, schema[toolpolicy.OriginalBooleanSchemaKey], want)
		}
	}
}
