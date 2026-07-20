package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestToolConstraintValidationRunsThroughEveryHTTPShape(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "m"}})

	tests := []struct {
		name   string
		path   string
		body   string
		status int
		want   string
	}{
		{
			"chat streaming invalid name",
			"/v1/chat/completions",
			`{"model":"m","stream":true,"messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
			"tool function names",
		},
		{
			"chat nonstream unsupported schema",
			"/v1/chat/completions",
			`{"model":"m","stream":false,"messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
			"uses oneOf",
		},
		{
			"chat constrained multimodal",
			"/v1/chat/completions",
			`{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"x"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}]}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object"}}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
			"not supported for multimodal",
		},
		{
			"responses streaming named undeclared",
			"/v1/responses",
			`{"model":"m","stream":true,"input":"x","tools":[{"type":"function","name":"safe","parameters":{"type":"object"}}],"tool_choice":{"type":"function","name":"missing"}}`,
			http.StatusBadRequest,
			"undeclared function",
		},
		{
			"responses nonstream nonobject history arguments",
			"/v1/responses",
			`{"model":"m","stream":false,"input":[{"type":"function_call","call_id":"c","name":"safe","arguments":"[1]"}]}`,
			http.StatusBadRequest,
			"arguments must be a JSON object",
		},
		{
			"messages streaming malformed parallel policy",
			"/v1/messages",
			`{"model":"m","stream":true,"messages":[{"role":"user","content":"x"}],"tools":[{"name":"safe","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":"yes"}}`,
			http.StatusBadRequest,
			"invalid",
		},
		{
			"messages nonstream orphan history",
			"/v1/messages",
			`{"model":"m","stream":false,"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"missing","content":"x"}]}]}`,
			http.StatusBadRequest,
			"no preceding assistant tool call",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(
				http.MethodPost, test.path, strings.NewReader(test.body))
			request.Header.Set("Authorization", "Bearer test-key")
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, request)
			if response.Code != test.status {
				t.Fatalf(
					"status = %d, want %d: %s",
					response.Code, test.status, response.Body.String())
			}
			if !strings.Contains(response.Body.String(), test.want) {
				t.Fatalf("response missing %q: %s", test.want, response.Body.String())
			}
		})
	}
}
