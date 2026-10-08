package response_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/relay"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Exercise provider chunks through the real relay, endpoint conversion and
// HTTP writer. Only lifecycle settlement is replaced; no account is involved.
func TestMessagesToolInputsPreserveJSONNumbers(t *testing.T) {
	for _, tc := range []struct {
		name, arguments, want string
	}{
		{"large integer", `{"id":9007199254740993}`, `{"id":9007199254740993}`},
		{"large negative integer", `{"offset":-9007199254740993}`, `{"offset":-9007199254740993}`},
		{"nested numbers", `{"point":{"x":0.1234567890123456789012345},"steps":[9007199254740993,1.25]}`, `{"point":{"x":0.1234567890123456789012345},"steps":[9007199254740993,1.25]}`},
		{"large exponent", `{"scale":1e400}`, `{"scale":1e400}`},
		{"ordinary values", `{"label":"station","enabled":true,"optional":null,"steps":[1,2],"point":{"x":1.25}}`, `{"label":"station","enabled":true,"optional":null,"steps":[1,2],"point":{"x":1.25}}`},
		{"empty arguments", "", `{}`},
		{"null arguments", `null`, `null`},
		{"non object arguments", `[1,2]`, `{}`},
		{"incomplete JSON", `{"id":1,`, `{}`},
		{"trailing garbage", `{"id":1} invalid`, `{}`},
		{"second JSON value", `{"id":1} {"id":2}`, `{}`},
	} {
		for _, shape := range []string{"complete response", "fragmented deltas"} {
			t.Run(tc.name+"/"+shape, func(t *testing.T) {
				pr := &registry.PendingRequest{
					RequestID: "tool-numbers", PublicModel: "public-model",
					ConsumerEndpoint: inreq.MessagesEndpoint,
					ChunkCh:          make(chan registry.ProviderChunk),
					CompleteCh:       make(chan protocol.UsageInfo, 1),
				}
				close(pr.ChunkCh)
				pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 3}
				close(pr.CompleteCh)
				completed := 0
				controller := &relay.Controller{Success: func(got *registry.PendingRequest) {
					if got != pr {
						t.Fatal("relay completed a different request")
					}
					completed++
				}}
				chunks := messagesToolNumberChunks(tc.arguments, shape == "complete response")
				recorder := httptest.NewRecorder()
				controller.NonStream(recorder, httptest.NewRequest(http.MethodPost, "/v1/messages", nil), pr, chunks, nil)
				if recorder.Code != http.StatusOK || completed != 1 {
					t.Fatalf("status=%d completions=%d body=%s", recorder.Code, completed, recorder.Body.String())
				}
				var response struct {
					Model      string `json:"model"`
					StopReason string `json:"stop_reason"`
					Content    []struct {
						Type  string          `json:"type"`
						ID    string          `json:"id"`
						Name  string          `json:"name"`
						Input json.RawMessage `json:"input"`
					} `json:"content"`
				}
				if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
					t.Fatalf("invalid response: %v; body=%s", err, recorder.Body.String())
				}
				if response.Model != "public-model" || response.StopReason != "tool_use" || len(response.Content) != 1 {
					t.Fatalf("unexpected response: %s", recorder.Body.String())
				}
				block := response.Content[0]
				if block.Type != "tool_use" || block.ID != "call-1" || block.Name != "lookup" {
					t.Fatalf("unexpected tool block: %s", recorder.Body.String())
				}
				if !reflect.DeepEqual(messagesToolNumberValue(t, string(block.Input)), messagesToolNumberValue(t, tc.want)) {
					t.Errorf("tool input changed: got %s, want %s", block.Input, tc.want)
				}

				// The existing streaming path sends the argument string verbatim;
				// non-streaming must preserve the same values when making an object.
				stream := httptest.NewRecorder()
				emitter := inresp.NewGenericEndpointStreamEmitter(stream, stream, pr)
				emitter.Start()
				for _, chunk := range messagesToolNumberChunks(tc.arguments, false) {
					emitter.HandleChunk(chunk)
				}
				emitter.Finish(protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 3})
				var streamed strings.Builder
				for _, line := range strings.Split(stream.Body.String(), "\n") {
					if !strings.HasPrefix(line, "data: ") {
						continue
					}
					var event struct {
						Delta struct {
							PartialJSON string `json:"partial_json"`
						} `json:"delta"`
					}
					if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
						t.Fatal(err)
					}
					streamed.WriteString(event.Delta.PartialJSON)
				}
				if streamed.String() != tc.arguments {
					t.Errorf("stream changed arguments: got %q, want %q", streamed.String(), tc.arguments)
				}
			})
		}
	}
}

func messagesToolNumberChunks(arguments string, complete bool) []string {
	quoted, _ := json.Marshal(arguments)
	if complete {
		return []string{`data: {"object":"chat.completion","choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call-1","type":"function","function":{"name":"lookup","arguments":` + string(quoted) + `}}]},"finish_reason":"tool_calls"}]}`}
	}
	// Split inside the numeric literal as well as its surrounding JSON syntax.
	chunks := []string{`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"lookup","arguments":""}}]}}]}`}
	for start := 0; start < len(arguments); start += 7 {
		fragment, _ := json.Marshal(arguments[start:min(start+7, len(arguments))])
		chunks = append(chunks, `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":`+string(fragment)+`}}]}}]}`)
	}
	return append(chunks, `data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`)
}

func messagesToolNumberValue(t *testing.T, value string) any {
	t.Helper()
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var result any
	if err := decoder.Decode(&result); err != nil {
		t.Fatalf("invalid comparison JSON %q: %v", value, err)
	}
	return result
}
