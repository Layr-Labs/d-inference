package promptcontract

import (
	"bytes"
	"errors"
	"testing"
)

type lowerCase struct {
	name     string
	endpoint Endpoint
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
			actual, err := LowerProviderBody(test.endpoint, []byte(test.body))
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
		{name: "invalid json", endpoint: EndpointChatCompletions, body: `{`, wantErr: ErrEndpointBodyInvalid},
		{name: "trailing value", endpoint: EndpointChatCompletions, body: `{} {}`, wantErr: ErrEndpointBodyInvalid},
		{name: "array body", endpoint: EndpointChatCompletions, body: `[]`, wantErr: ErrEndpointBodyNotObject},
		{name: "string body", endpoint: EndpointCompletions, body: `"x"`, wantErr: ErrEndpointBodyNotObject},
		{name: "unknown endpoint", endpoint: Endpoint("embeddings"), body: `{}`, wantErr: ErrEndpointBodyInvalid},
		{
			name:     "responses media inside function call output",
			endpoint: EndpointResponses,
			body:     `{"input":[{"type":"function_call_output","call_id":"c","output":[{"type":"input_file"}]}]}`,
			wantErr:  ErrEndpointBodyUnsupported,
		},
		{
			name:     "messages document is media",
			endpoint: EndpointMessages,
			body:     `{"messages":[{"role":"user","content":[{"type":"document"}]}]}`,
			wantErr:  ErrEndpointBodyUnsupported,
		},
	})
}

func TestLowerProviderBodyChatCompletionsPassesThrough(t *testing.T) {
	runLowerCases(t, []lowerCase{{
		name:     "chat body copied unchanged",
		endpoint: EndpointChatCompletions,
		body:     `{"model":"m","messages":[{"role":"user","content":"hi <b>"}],"max_tokens":7,"endpoint":"chat"}`,
		want:     `{"model":"m","messages":[{"role":"user","content":"hi <b>"}],"max_tokens":7,"endpoint":"chat"}`,
	}})
}

func TestLowerProviderBodyCompletionsPrompt(t *testing.T) {
	runLowerCases(t, []lowerCase{
		{
			name:     "string prompt becomes one user message",
			endpoint: EndpointCompletions,
			body:     `{"model":"m","prompt":"hello","endpoint":"completions","max_tokens":5}`,
			want:     `{"model":"m","max_tokens":5,"messages":[{"role":"user","content":"hello"}]}`,
		},
		{
			name:     "single element prompt array",
			endpoint: EndpointCompletions,
			body:     `{"prompt":["only"]}`,
			want:     `{"messages":[{"role":"user","content":"only"}]}`,
		},
		{name: "two element prompt array", endpoint: EndpointCompletions, body: `{"prompt":["a","b"]}`, wantErr: ErrEndpointBodyUnsupported},
		{name: "empty prompt array", endpoint: EndpointCompletions, body: `{"prompt":[]}`, wantErr: ErrEndpointBodyUnsupported},
		{name: "token id prompt", endpoint: EndpointCompletions, body: `{"prompt":[1]}`, wantErr: ErrEndpointBodyUnsupported},
		{name: "missing prompt", endpoint: EndpointCompletions, body: `{"model":"m"}`, wantErr: ErrEndpointBodyInvalid},
		{name: "numeric prompt", endpoint: EndpointCompletions, body: `{"prompt":3}`, wantErr: ErrEndpointBodyInvalid},
	})
}
