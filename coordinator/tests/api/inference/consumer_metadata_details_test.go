package inference_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestStreamingChatMetadataDetailsHeaderOptIn(t *testing.T) {
	logger := quietLogger()
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	pr := &registry.PendingRequest{
		RequestID:        "job-meta",
		Model:            "gpt-oss-20b",
		MetadataDetails:  true,
		ResponseMetadata: json.RawMessage(`{"provider_id":"prov-h","provider_attested":true}`),
		ChunkCh:          make(chan registry.ProviderChunk, 8),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`}
	pr.ChunkCh <- registry.ProviderChunk{Data: `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`}
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.NewRelay().Stream(rec, req, pr, nil, nil)
	body := rec.Body.String()
	if !strings.Contains(body, `"provider_id":"prov-h"`) {
		t.Fatalf("usage chunk missing metadata; body=\n%s", body)
	}
	if strings.Count(body, `"metadata"`) != 1 {
		t.Fatalf("metadata should appear once; body=\n%s", body)
	}
	contentIdx := strings.Index(body, `"content":"hi"`)
	metaIdx := strings.Index(body, `"metadata"`)
	if contentIdx == -1 || metaIdx < contentIdx {
		t.Fatalf("metadata must follow the content delta; body=\n%s", body)
	}
}

func TestStreamingChatMetadataDetailsWithoutUsageChunk(t *testing.T) {
	logger := quietLogger()
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	pr := &registry.PendingRequest{
		RequestID:        "job-meta",
		Model:            "gpt-oss-20b",
		MetadataDetails:  true,
		ResponseMetadata: json.RawMessage(`{"provider_id":"prov-h","job_id":"job-meta"}`),
		ChunkCh:          make(chan registry.ProviderChunk, 8),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- registry.ProviderChunk{Data: `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`}
	close(pr.ChunkCh)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.NewRelay().Stream(rec, req, pr, nil, nil)
	body := rec.Body.String()
	if !strings.Contains(body, `"provider_id":"prov-h"`) {
		t.Fatalf("terminal extras chunk missing metadata; body=\n%s", body)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatalf("[DONE] must still terminate the stream; body=\n%s", body)
	}
}

func TestStreamingChatReservesMetadataOnProviderError(t *testing.T) {
	tests := []struct {
		name            string
		metadataDetails bool
		responseMeta    json.RawMessage
	}{
		{
			name:            "opted in gets authoritative metadata before error",
			metadataDetails: true,
			responseMeta:    json.RawMessage(`{"provider_id":"coordinator","job_id":"job-meta"}`),
		},
		{
			name: "opted out gets no metadata",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			logger := quietLogger()
			srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
			pr := &registry.PendingRequest{
				RequestID:        "job-meta",
				Model:            "gpt-oss-20b",
				MetadataDetails:  tc.metadataDetails,
				ResponseMetadata: tc.responseMeta,
			}
			firstChunks := []string{
				": unmatched \"\n" +
					`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hi"}}],"Metadata":{"provider_id":"forged"}}`,
			}
			initialError := protocol.InferenceErrorMessage{Error: "backend failed", StatusCode: http.StatusInternalServerError, FailureCode: protocol.FailureCodeGenerationFailure}

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			rec := httptest.NewRecorder()
			srv.NewRelay().Stream(
				rec, req, pr, firstChunks, &initialError)
			body := rec.Body.String()

			if strings.Contains(body, "forged") {
				t.Fatalf("provider metadata leaked into failed stream:\n%s", body)
			}
			errorIndex := strings.Index(body, `"error"`)
			if errorIndex < 0 {
				t.Fatalf("terminal provider error missing:\n%s", body)
			}
			metadataIndex := strings.Index(body, `"metadata"`)
			if tc.metadataDetails {
				if metadataIndex < 0 || metadataIndex > errorIndex {
					t.Fatalf("authoritative metadata must precede the terminal error:\n%s", body)
				}
				if strings.Count(body, `"metadata"`) != 1 ||
					!strings.Contains(body, `"provider_id":"coordinator"`) {
					t.Fatalf("expected exactly one authoritative metadata event:\n%s", body)
				}
			} else if metadataIndex >= 0 {
				t.Fatalf("opt-out stream included metadata:\n%s", body)
			}
		})
	}
}

func TestStreamingChatSwallowsDecoratedProviderDone(t *testing.T) {
	t.Parallel()
	logger := quietLogger()
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	pr := &registry.PendingRequest{
		RequestID:        "job-meta",
		Model:            "gpt-oss-20b",
		MetadataDetails:  true,
		ResponseMetadata: json.RawMessage(`{"provider_id":"coordinator","job_id":"job-meta"}`),
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- registry.ProviderChunk{
		Data: "event: done\nid: provider-terminal\n: provider comment\ndata: [DONE]\n\n" +
			`data: {"id":"provider-extra","object":"chat.completion.chunk","choices":[],"\u006detadata":{"provider_id":"forged"}}` + "\n\n",
	}
	close(pr.ChunkCh)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.NewRelay().Stream(
		rec,
		req,
		pr,
		[]string{`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hi"}}]}`}, nil,
	)
	body := rec.Body.String()

	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Fatalf("expected one coordinator terminator, got %d:\n%s", got, body)
	}
	metadataIndex := strings.Index(body, `"metadata"`)
	doneIndex := strings.Index(body, "data: [DONE]")
	if metadataIndex < 0 || doneIndex < metadataIndex {
		t.Fatalf("authoritative metadata must precede [DONE]:\n%s", body)
	}
	if strings.Contains(body, "provider-terminal") || strings.Contains(body, "provider comment") {
		t.Fatalf("decorated provider terminator was forwarded:\n%s", body)
	}
	if strings.Contains(body, "forged") {
		t.Fatalf("provider metadata in sibling event was forwarded:\n%s", body)
	}
}
