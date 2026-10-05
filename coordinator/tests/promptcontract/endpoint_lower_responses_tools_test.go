package promptcontract_test

import (
	"testing"

	lowering "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/endpoint"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestLowerResponsesToolsChoiceAndFormat(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "flat and nested function tools",
			endpoint: sidecar.EndpointResponses,
			body: `{"input":"hi","tools":["skip",{"type":"function","name":"f","description":"d","parameters":{"type":"object"},"strict":true},
				{"function":{"name":"g"}},{"name":"h"}]}`,
			want: `{"messages":[{"role":"user","content":"hi"}],"tools":[
				{"type":"function","function":{"name":"f","description":"d","parameters":{"type":"object"}}},
				{"type":"function","function":{"name":"g"}},
				{"type":"function","function":{"name":"h"}}]}`,
		},
		{
			name:     "empty tools list is left as given",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","tools":[]}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"tools":[]}`,
		},
		{
			name:     "non list tools are left as given",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","tools":"x"}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"tools":"x"}`,
		},
		{name: "builtin tool", endpoint: sidecar.EndpointResponses, body: `{"input":"hi","tools":[{"type":"web_search"}]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "flat tool without name", endpoint: sidecar.EndpointResponses, body: `{"input":"hi","tools":[{"type":"function"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{
			name:     "string choice passes through",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","tool_choice":"required"}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"tool_choice":"required"}`,
		},
		{
			name:     "non function object choice passes through",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","tool_choice":{"type":"allowed_tools","mode":"auto"}}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"allowed_tools","mode":"auto"}}`,
		},
		{
			name:     "function choice is nested",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","tool_choice":{"type":"function","name":"f"}}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","function":{"name":"f"}}}`,
		},
		{name: "function choice without name", endpoint: sidecar.EndpointResponses, body: `{"input":"hi","tool_choice":{"type":"function"}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{
			name:     "json object format",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","text":{"format":{"type":"json_object"}}}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_object"}}`,
		},
		{
			name:     "json schema format keeps the whole format object",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","text":{"format":{"type":"json_schema","name":"s","schema":{"type":"object"}}}}`,
			want: `{"messages":[{"role":"user","content":"hi"}],
				"response_format":{"type":"json_schema","json_schema":{"type":"json_schema","name":"s","schema":{"type":"object"}}}}`,
		},
		{
			name:     "plain text format and missing format are dropped",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","text":{"format":{"type":"text"},"verbosity":"low"}}`,
			want:     `{"messages":[{"role":"user","content":"hi"}]}`,
		},
		{
			name:     "text without format object is dropped",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","text":{"format":"json"}}`,
			want:     `{"messages":[{"role":"user","content":"hi"}]}`,
		},
		{
			name:     "first positive max token key wins",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":"hi","max_tokens":0,"max_completion_tokens":"9","max_output_tokens":12}`,
			want:     `{"messages":[{"role":"user","content":"hi"}],"max_tokens":12,"max_completion_tokens":"9"}`,
		},
	})
}

func TestLowerResponsesInputItems(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "function calls coalesce and outputs become tool messages",
			endpoint: sidecar.EndpointResponses,
			body: `{"input":[7,{"type":"reasoning"},{"no_role":true},
				{"type":"message","content":[{"type":"input_text","text":"q"},"s",""]},
				{"type":"function_call","call_id":"c1","name":"f","arguments":"{\"a\":1}"},
				{"type":"function_call","id":"i2","name":"g"},
				{"type":"function_call","call_id":5,"id":"i3","name":"h","arguments":"{}"},
				{"type":"function_call_output","call_id":"c1","output":{"ok":true}},
				{"role":"developer","content":null}]}`,
			want: `{"messages":[
				{"role":"user","content":"q\ns"},
				{"role":"assistant","content":"","tool_calls":[
					{"id":"c1","type":"function","function":{"name":"f","arguments":"{\"a\":1}"}},
					{"id":"i2","type":"function","function":{"name":"g","arguments":"{}"}},
					{"id":"i3","type":"function","function":{"name":"h","arguments":"{}"}}]},
				{"role":"tool","tool_call_id":"c1","content":"{\"ok\":true}"},
				{"role":"system","content":""}]}`,
		},
		{name: "input missing", endpoint: sidecar.EndpointResponses, body: `{"model":"m"}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "input number", endpoint: sidecar.EndpointResponses, body: `{"input":1}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "input with no messages", endpoint: sidecar.EndpointResponses, body: `{"input":[{"type":"reasoning"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "unknown item type", endpoint: sidecar.EndpointResponses, body: `{"input":[{"type":"web_search_call"}]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "unknown role on typed message", endpoint: sidecar.EndpointResponses, body: `{"input":[{"type":"message","role":"critic","content":"x"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "unknown role on untyped message", endpoint: sidecar.EndpointResponses, body: `{"input":[{"role":"critic","content":"x"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "non string call arguments", endpoint: sidecar.EndpointResponses, body: `{"input":[{"type":"function_call","call_id":"c","name":"f","arguments":{}}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
	})
}
