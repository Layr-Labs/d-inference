package promptcontract_test

import (
	"bytes"
	"errors"
	"testing"

	lowering "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/endpoint"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

type lowerCase struct {
	name     string
	endpoint sidecar.Endpoint
	body     string
	want     string
	wantErr  error
}

// runLowerCases lowers each body and compares the result with the canonical
// form of want, so the table can list keys in any order.
func runLowerCases(t *testing.T, tests []lowerCase) {
	t.Helper()
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			actual, err := lowering.LowerProviderBody(test.endpoint, []byte(test.body))
			if test.wantErr != nil {
				if !errors.Is(err, test.wantErr) {
					t.Fatalf("error = %v, want %v", err, test.wantErr)
				}
				if actual != nil {
					t.Fatalf("body = %s, want nil on error", actual)
				}
				return
			}
			if err != nil {
				t.Fatalf("lower: %v", err)
			}
			want := canonicalJSON(t, []byte(test.want))
			if !bytes.Equal(actual, want) {
				t.Fatalf("body mismatch\nactual: %s\nwant:   %s", actual, want)
			}
		})
	}
}

func TestLowerProviderBodyRejectsMalformedEnvelopes(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{name: "invalid json", endpoint: sidecar.EndpointChatCompletions, body: `{`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "trailing value", endpoint: sidecar.EndpointChatCompletions, body: `{} {}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "array body", endpoint: sidecar.EndpointChatCompletions, body: `[]`, wantErr: lowering.ErrEndpointBodyNotObject},
		{name: "string body", endpoint: sidecar.EndpointCompletions, body: `"x"`, wantErr: lowering.ErrEndpointBodyNotObject},
		{name: "unknown endpoint", endpoint: sidecar.Endpoint("embeddings"), body: `{}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{
			name:     "responses media inside function call output",
			endpoint: sidecar.EndpointResponses,
			body:     `{"input":[{"type":"function_call_output","call_id":"c","output":[{"type":"input_file"}]}]}`,
			wantErr:  lowering.ErrEndpointBodyUnsupported,
		},
		{
			name:     "messages document is media",
			endpoint: sidecar.EndpointMessages,
			body:     `{"messages":[{"role":"user","content":[{"type":"document"}]}]}`,
			wantErr:  lowering.ErrEndpointBodyUnsupported,
		},
	})
}

func TestLowerProviderBodyChatCompletionsPassesThrough(t *testing.T) {
	runLowerCases(t, []lowerCase{{
		name:     "chat body copied unchanged",
		endpoint: sidecar.EndpointChatCompletions,
		body:     `{"model":"m","messages":[{"role":"user","content":"hi <b>"}],"max_tokens":7,"endpoint":"chat"}`,
		want:     `{"model":"m","messages":[{"role":"user","content":"hi <b>"}],"max_tokens":7,"endpoint":"chat"}`,
	}})
}

func TestLowerProviderBodyCompletionsPrompt(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "string prompt becomes one user message",
			endpoint: sidecar.EndpointCompletions,
			body:     `{"model":"m","prompt":"hello","endpoint":"completions","max_tokens":5}`,
			want:     `{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"hello"}]}`,
		},
		{
			name:     "single element prompt array",
			endpoint: sidecar.EndpointCompletions,
			body:     `{"prompt":["only"]}`,
			want:     `{"messages":[{"role":"user","content":"only"}]}`,
		},
		{name: "two element prompt array", endpoint: sidecar.EndpointCompletions, body: `{"prompt":["a","b"]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "empty prompt array", endpoint: sidecar.EndpointCompletions, body: `{"prompt":[]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "token id prompt", endpoint: sidecar.EndpointCompletions, body: `{"prompt":[1]}`, wantErr: lowering.ErrEndpointBodyUnsupported},
		{name: "missing prompt", endpoint: sidecar.EndpointCompletions, body: `{"model":"m"}`, wantErr: lowering.ErrEndpointBodyInvalid},
		{name: "numeric prompt", endpoint: sidecar.EndpointCompletions, body: `{"prompt":3}`, wantErr: lowering.ErrEndpointBodyInvalid},
	})
}
