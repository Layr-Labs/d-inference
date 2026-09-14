package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// End-to-end through the real HTTP handler with a non-Gemma model that has no
// constraint-capable provider (the production gpt-oss-20b situation). The union
// and $ref shapes must clear admission and be answered by the ROUTING
// capability gate, never by a 422 schema verdict the auto path never needed.
func TestAutoToolSchemaReachesRoutingOverHTTP(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "gpt-oss-20b"}})

	bodies := map[string]string{
		"anyOf union": `{"model":"gpt-oss-20b","messages":[{"role":"user","content":"x"}],
  "tool_choice":"auto","tools":[{"type":"function","function":{"name":"set_config_value","parameters":
  {"type":"object","properties":{"value":{"anyOf":[{"type":"string"},
  {"type":"object","properties":{"source":{"type":"string"}}}]}},"required":["value"]}}}]}`,
		"$defs/$ref": `{"model":"gpt-oss-20b","messages":[{"role":"user","content":"x"}],
  "tool_choice":"auto","tools":[{"type":"function","function":{"name":"f","parameters":
  {"type":"object","$defs":{"P":{"type":"string"}},"properties":{"p":{"$ref":"#/$defs/P"}}}}}]}`,
	}
	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(
				http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			request.Header.Set("Authorization", "Bearer test-key")
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, request)
			if response.Code != http.StatusServiceUnavailable ||
				!strings.Contains(response.Body.String(), "supports tool calls") {
				t.Fatalf("auto request did not reach the routing gate: %d %s",
					response.Code, response.Body.String())
			}
		})
	}
}
