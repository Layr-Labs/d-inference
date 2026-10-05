package promptcontract_test

import (
	"testing"

	lowering "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/endpoint"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestLowerMessagesSystemAndContentText(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "system block list keeps only text parts joined by newline",
			endpoint: sidecar.EndpointMessages,
			body: `{"system":[{"type":"text","text":"a"},{"type":"other","text":"skip"},"raw",{"type":"text","text":3},{"type":"text","text":"b"}],
				"messages":[{"role":"user","content":"hi"}]}`,
			want: `{"messages":[{"role":"system","content":"a\nb"},{"role":"user","content":"hi"}]}`,
		},
		{
			name:     "empty system is dropped",
			endpoint: sidecar.EndpointMessages,
			body:     `{"system":"","messages":[{"role":"assistant","content":"x"}]}`,
			want:     `{"messages":[{"role":"assistant","content":"x"}]}`,
		},
		{
			name:     "non text system is dropped",
			endpoint: sidecar.EndpointMessages,
			body:     `{"system":5,"messages":[{"role":"user","content":7}]}`,
			want:     `{"messages":[{"role":"user","content":""}]}`,
		},
		{
			name:     "tool result block content becomes text",
			endpoint: sidecar.EndpointMessages,
			body: `{"messages":[{"role":"user","content":[{"type":"text","text":"before"},
				{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"r1"},{"type":"text","text":"r2"}]},
				{"type":"text","text":"after"}]}]}`,
			want: `{"messages":[{"role":"user","content":"before"},{"role":"tool","tool_call_id":"t1","content":"r1\nr2"},{"role":"user","content":"after"}]}`,
		},
		{
			name:     "assistant thinking and tool use",
			endpoint: sidecar.EndpointMessages,
			body: `{"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"ok"},
				{"type":"tool_use","id":"u1","name":"f"},{"type":"tool_use","id":"u2","name":"g","input":{"k":1}}]}]}`,
			want: `{"messages":[{"role":"assistant","content":"ok","reasoning_content":"hm","tool_calls":[
				{"id":"u1","type":"function","function":{"name":"f","arguments":"{}"}},
				{"id":"u2","type":"function","function":{"name":"g","arguments":"{\"k\":1}"}}]}]}`,
		},
		{name: "messages not a list", endpoint: sidecar.EndpointMessages, body: `{"messages":{}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "message not an object", endpoint: sidecar.EndpointMessages, body: `{"messages":["x"]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "message without role", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"content":"x"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "system role with parts", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"system","content":[]}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "system role with text", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"system","content":"x"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "assistant part not object", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"assistant","content":[1]}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "assistant tool use without id", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"assistant","content":[{"type":"tool_use","name":"f"}]}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "assistant unknown part", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"assistant","content":[{"type":"server_tool_use"}]}]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "user part not object", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"user","content":[1]}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "tool result without id", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"user","content":[{"type":"tool_result"}]}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "user unknown part", endpoint: sidecar.EndpointMessages, body: `{"messages":[{"role":"user","content":[{"type":"search_result"}]}]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "stop sequences not a list", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"stop_sequences":"END"}`, wantErr: lowering.ErrEndpointBodyInvalid},
	})
}

func TestLowerMessagesToolsAndToolChoice(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "tool defaults for description and schema",
			endpoint: sidecar.EndpointMessages,
			body:     `{"messages":[],"tools":[{"name":"f"},{"name":"g","description":"d","input_schema":{"type":"object","properties":{}}}]}`,
			want: `{"messages":[],"tools":[
				{"type":"function","function":{"name":"f","description":"","parameters":{"type":"object"}}},
				{"type":"function","function":{"name":"g","description":"d","parameters":{"type":"object","properties":{}}}}]}`,
		},
		{name: "choice auto", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"auto"}}`, want: `{"messages":[],"tool_choice":"auto"}`},
		{name: "choice any becomes required", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"any"}}`, want: `{"messages":[],"tool_choice":"required"}`},
		{name: "choice none", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"none"}}`, want: `{"messages":[],"tool_choice":"none"}`},
		{
			name:     "choice tool names a function and disables parallel calls",
			endpoint: sidecar.EndpointMessages,
			body:     `{"messages":[],"tool_choice":{"type":"tool","name":"f","disable_parallel_tool_use":true}}`,
			want:     `{"messages":[],"tool_choice":{"type":"function","function":{"name":"f"}},"parallel_tool_calls":false}`,
		},
		{
			name:     "parallel tool use kept when not disabled",
			endpoint: sidecar.EndpointMessages,
			body:     `{"messages":[],"tool_choice":{"type":"auto","disable_parallel_tool_use":false}}`,
			want:     `{"messages":[],"tool_choice":"auto","parallel_tool_calls":true}`,
		},
		{name: "choice tool without name", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"tool"}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "choice unknown type", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"all"}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "choice as string", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":"auto"}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "disable parallel not bool", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tool_choice":{"type":"auto","disable_parallel_tool_use":"yes"}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "tools not a list", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tools":{}}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "tool not an object", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tools":["f"]}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "tool without name", endpoint: sidecar.EndpointMessages, body: `{"messages":[],"tools":[{"description":"d"}]}`, wantErr: lowering.ErrEndpointBodyInvalid},
	})
}
