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
