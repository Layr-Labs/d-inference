package promptwork_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/promptwork"
)

func TestPromptShapeUsesActualJSONBytesAndToolHistory(t *testing.T) {
	tool := `{"type":"function","function":{"name":"f","parameters":{"description":"\\u00e9"}}}`
	call := `{"id":"call","type":"function","function":{"name":"f","arguments":"{}"}}`
	user := `{"role":"user","content":"é"}`
	assistant := `{"role":"assistant","content":null,"tool_calls":[` + call + `]}`
	result := `{"role":"tool","tool_call_id":"call","content":"result"}`
	body := []byte(`{"reasoning":{"enabled":false},"messages":[` + user + `,` + assistant + `,` + result + `],"tools":[` + tool + `]}`)
	shape, ok := production.ShapeFromBody(body)
	if !ok || shape.BodyBytes != len(body) || shape.MessageCount != 3 || shape.MessageBytes != len(user)+len(assistant)+len(result) || shape.ToolDefinitionCount != 1 || shape.ToolDefinitionBytes != len(tool) || shape.ToolCallCount != 1 || shape.ToolCallBytes != len(call) || shape.ToolResultCount != 1 || shape.ToolResultBytes != len(result) || shape.AssistantMessageCount != 1 {
		t.Fatalf("numeric shape = %+v, known=%t", shape, ok)
	}
}

func TestPromptShapeRejectsUnsupportedForms(t *testing.T) {
	for _, body := range []string{
		`{`, `null`, `{"reasoning":{"enabled":false},"messages":[]}`, `{"reasoning":{"enabled":false},"messages":[{"role":"future","content":"x"}]}`,
		`{"reasoning":{"enabled":false},"messages":[{"role":"user","content":[{"type":"image_url","image_url":"x"}]}]}`,
		`{"reasoning":{"enabled":false},"messages":[{"role":"assistant","function_call":{"name":"f"}}]}`,
		`{"reasoning":{"enabled":false},"messages":[{"role":"user","content":"x"}],"tools":[{"type":"custom"}]}`,
	} {
		if _, ok := production.ShapeFromBody([]byte(body)); ok {
			t.Fatalf("unsupported shape qualified: %s", body)
		}
	}
}
