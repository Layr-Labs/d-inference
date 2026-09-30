package promptcontract

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestLowerProviderBodyMatchesProductionVectors(t *testing.T) {
	type fixtureCase struct {
		ID           string          `json:"id"`
		Endpoint     Endpoint        `json:"endpoint"`
		RequestBody  json.RawMessage `json:"request_body"`
		ProviderBody json.RawMessage `json:"provider_body"`
	}
	var corpus struct {
		SchemaVersion uint32 `json:"schema_version"`
		Models        []struct {
			ModelID              string        `json:"model_id"`
			CacheRoutingEligible bool          `json:"cache_routing_eligible"`
			Cases                []fixtureCase `json:"cases"`
		} `json:"models"`
	}
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "fixtures", "prompt-contract", "v1", "production_vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if corpus.SchemaVersion != 1 {
		t.Fatalf("schema version = %d, want 1", corpus.SchemaVersion)
	}

	compared := 0
	for _, model := range corpus.Models {
		if !model.CacheRoutingEligible {
			continue
		}
		for _, fixture := range model.Cases {
			t.Run(model.ModelID+"/"+fixture.ID, func(t *testing.T) {
				actual, err := LowerProviderBody(fixture.Endpoint, fixture.RequestBody)
				if err != nil {
					t.Fatalf("lower provider body: %v", err)
				}
				expected := canonicalJSON(t, fixture.ProviderBody)
				if !bytes.Equal(actual, expected) {
					t.Fatalf("provider body mismatch\nactual:   %s\nexpected: %s", actual, fixture.ProviderBody)
				}
			})
			compared++
		}
	}
	if compared == 0 {
		t.Fatal("no cache-routing-eligible production cases compared")
	}
}

func TestLowerProviderBodyRejectsMediaForCachePlanning(t *testing.T) {
	tests := []struct {
		name     string
		endpoint Endpoint
		body     string
	}{
		{
			name:     "chat",
			endpoint: EndpointChatCompletions,
			body:     `{"messages":[{"role":"user","content":[{"type":"image_url"}]}]}`,
		},
		{
			name:     "responses",
			endpoint: EndpointResponses,
			body:     `{"input":[{"type":"message","content":[{"type":"input_image"}]}]}`,
		},
		{
			name:     "messages",
			endpoint: EndpointMessages,
			body:     `{"messages":[{"role":"user","content":[{"type":"image"}]}]}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := LowerProviderBody(test.endpoint, []byte(test.body))
			if !errors.Is(err, ErrEndpointBodyUnsupported) {
				t.Fatalf("error = %v, want ErrEndpointBodyUnsupported", err)
			}
		})
	}
}

func TestLowerProviderBodyMatchesRustEdgeSemantics(t *testing.T) {
	tests := []struct {
		name     string
		endpoint Endpoint
		body     string
		want     string
		wantErr  error
	}{
		{
			name:     "responses explicit empty role is invalid",
			endpoint: EndpointResponses,
			body:     `{"input":[{"type":"message","role":"","content":"x"}]}`,
			wantErr:  ErrEndpointBodyInvalid,
		},
		{
			name:     "messages explicit null tools is invalid",
			endpoint: EndpointMessages,
			body:     `{"messages":[],"tools":null}`,
			wantErr:  ErrEndpointBodyInvalid,
		},
		{
			name:     "messages explicit null tool choice is invalid",
			endpoint: EndpointMessages,
			body:     `{"messages":[],"tool_choice":null}`,
			wantErr:  ErrEndpointBodyInvalid,
		},
		{
			name:     "messages stop sequences become provider stop",
			endpoint: EndpointMessages,
			body:     `{"model":"test","messages":[],"stop_sequences":["DONE","END"]}`,
			want:     `{"messages":[],"model":"test","stop":["DONE","END"]}`,
		},
		{
			name:     "messages non-string stop sequence is invalid",
			endpoint: EndpointMessages,
			body:     `{"messages":[],"stop_sequences":["DONE",1]}`,
			wantErr:  ErrEndpointBodyInvalid,
		},
		{
			name:     "serialized response content does not HTML escape",
			endpoint: EndpointResponses,
			body:     `{"input":[{"role":"user","content":{"value":"<tag>&"}}]}`,
			want:     `{"messages":[{"content":"{\"value\":\"<tag>&\"}","role":"user"}]}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual, err := LowerProviderBody(test.endpoint, []byte(test.body))
			if test.wantErr != nil {
				if !errors.Is(err, test.wantErr) {
					t.Fatalf("error = %v, want %v", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(actual, []byte(test.want)) {
				t.Fatalf("body = %s, want %s", actual, test.want)
			}
		})
	}
}

func canonicalJSON(t *testing.T, encoded []byte) []byte {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		t.Fatal(err)
	}
	canonical, err := marshalEndpointJSON(value)
	if err != nil {
		t.Fatal(err)
	}
	return canonical
}

func TestLowerProviderBodyRejectsAudioForCachePlanning(t *testing.T) {
	for _, kind := range []string{"input_audio", "audio_url"} {
		payloads := []struct {
			name string
			part map[string]any
		}{
			{"missing", map[string]any{"type": kind}},
			{"null", map[string]any{"type": kind, kind: nil}},
			{"scalar", map[string]any{"type": kind, kind: 42}},
			{"wav", map[string]any{"type": kind, kind: map[string]any{"data": "AAAA", "format": "wav"}}},
			{"unsupported-format", map[string]any{"type": kind, kind: map[string]any{"data": "AAAA", "format": "mp3"}}},
			{"remote-reference", map[string]any{"type": kind, kind: map[string]any{"url": "https://example.invalid/private"}}},
		}
		for _, payload := range payloads {
			for _, test := range []struct {
				name     string
				endpoint Endpoint
				body     map[string]any
			}{
				{"chat", EndpointChatCompletions, map[string]any{"messages": []any{map[string]any{"role": "user", "content": []any{payload.part}}}}},
				{"chat-tool", EndpointChatCompletions, map[string]any{"messages": []any{map[string]any{"role": "tool", "tool_call_id": "c", "content": []any{payload.part}}}}},
				{"responses-message", EndpointResponses, map[string]any{"input": []any{map[string]any{"type": "message", "role": "user", "content": []any{payload.part}}}}},
				{"responses-tool-array", EndpointResponses, map[string]any{"input": []any{map[string]any{"type": "function_call_output", "call_id": "c", "output": []any{payload.part}}}}},
				{"responses-tool-object", EndpointResponses, map[string]any{"input": []any{map[string]any{"type": "function_call_output", "call_id": "c", "output": payload.part}}}},
				{"messages-tool", EndpointMessages, map[string]any{"messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": "c", "content": []any{payload.part}}}}}}},
			} {
				t.Run(kind+"/"+payload.name+"/"+test.name, func(t *testing.T) {
					body, err := json.Marshal(test.body)
					if err != nil {
						t.Fatal(err)
					}
					_, err = LowerProviderBody(test.endpoint, body)
					if !errors.Is(err, ErrEndpointBodyUnsupported) {
						t.Fatalf("error = %v, want cache ineligible", err)
					}
				})
			}
		}
	}
}

func TestLowerProviderBodyKeepsAudioWordsAndToolArgumentsAsText(t *testing.T) {
	body := []byte(`{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"input_audio audio_url"}]},{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":"{\"type\":\"input_audio\"}"}}]}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"kind":{"type":"audio_url"}}}}}],"metadata":{"content":{"type":"input_audio"}}}`)
	got, err := LowerProviderBody(EndpointChatCompletions, body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, canonicalJSON(t, body)) {
		t.Fatal("text/arguments changed")
	}
	for _, body := range []string{
		`{"input":"say input_audio and audio_url"}`,
		`{"input":[{"type":"function_call","call_id":"c","name":"f","arguments":"{\"type\":\"audio_url\"}"},{"type":"function_call_output","call_id":"c","output":"input_audio is plain text"}]}`,
	} {
		if _, err := LowerProviderBody(EndpointResponses, []byte(body)); err != nil {
			t.Fatalf("plain Responses history refused: %v", err)
		}
	}
}
