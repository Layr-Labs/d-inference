package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// These responses pin the HTTP boundary independently of toolpolicy's error
// representation, including errors after endpoint lowering.
func TestToolPolicyHTTPErrorContract(t *testing.T) {
	srv, _ := testServer(t)
	cases := []struct {
		name, path, body, message, param string
		status                           int
	}{
		{
			name: "chat invalid declaration", path: "/v1/chat/completions",
			body:    `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
			message: "tool function names must match ^[a-zA-Z0-9_-]{1,64}$",
			param:   "tools[0].function.name", status: http.StatusBadRequest,
		},
		{
			name: "chat unsupported schema", path: "/v1/chat/completions",
			body:    `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]}}}}}],"tool_choice":"required"}`,
			message: "f.parameters.properties.x uses oneOf",
			param:   "tools", status: http.StatusUnprocessableEntity,
		},
		{
			name: "responses forged marker", path: "/v1/responses",
			body:    `{"model":"m","input":"x","tools":[{"type":"function","name":"f","parameters":{"type":"object","properties":{"x":{"type":"string","x-darkbloom-original-boolean-schema":true}}}}]}`,
			message: "tool schema contains reserved internal metadata",
			param:   "tools", status: http.StatusBadRequest,
		},
		{
			name: "messages orphan history", path: "/v1/messages",
			body:    `{"model":"m","messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"missing","content":"x"}]}]}`,
			message: "tool message has no preceding assistant tool call",
			param:   "messages[0].tool_call_id", status: http.StatusBadRequest,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(tc.body))
			request.Header.Set("Authorization", "Bearer test-key")
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, request)
			if response.Code != tc.status {
				t.Fatalf("status = %d, want %d: %s", response.Code, tc.status, response.Body.String())
			}
			var envelope struct {
				Error struct {
					Type, Message, Param string
				}
			}
			if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Error.Type != "invalid_request_error" ||
				envelope.Error.Message != tc.message || envelope.Error.Param != tc.param {
				t.Fatalf("HTTP error = %+v; want invalid_request_error, %q, %q",
					envelope.Error, tc.message, tc.param)
			}
		})
	}
}
