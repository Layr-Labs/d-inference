package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func identityRegressionEvents(t *testing.T, body string) []map[string]any {
	t.Helper()
	var events []map[string]any
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "data: ") || line == "data: [DONE]" {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
	return events
}

func TestChatStreamMetadataRetainsIdentity(t *testing.T) {
	for _, usageOnly := range []bool{false, true} {
		name := "finish-with-usage"
		if usageOnly {
			name = "usage-only"
		}
		t.Run(name, func(t *testing.T) {
			logger := quietLogger()
			srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
			pr := &registry.PendingRequest{
				RequestID: "coordinator-job", Model: "fixture-model", SESignature: "unchanged-signature", ResponseHash: "unchanged-hash",
				MetadataDetails: true, ResponseMetadata: json.RawMessage(`{"job_id":"coordinator-job"}`),
				ChunkCh: make(chan registry.ProviderChunk, 4), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
				CompleteCh: make(chan protocol.UsageInfo, 1),
			}
			content := `data: {"id":"native-response","object":"chat.completion.chunk","created":123,"model":"fixture-model","choices":[{"index":0,"delta":{"content":"kept"}}]}`
			pr.ChunkCh <- registry.ProviderChunk{Data: content}
			finish := `data: {"id":"native-response","object":"chat.completion.chunk","created":123,"model":"fixture-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`
			pr.ChunkCh <- registry.ProviderChunk{Data: finish}
			if usageOnly {
				pr.ChunkCh <- registry.ProviderChunk{Data: `data: {"id":"native-response","object":"chat.completion.chunk","created":123,"model":"fixture-model","choices":[],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}`}
			}
			pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 2, CompletionTokens: 1}
			close(pr.ChunkCh)
			rec := httptest.NewRecorder()
			srv.handleStreamingResponseWithFirstChunkAndError(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr, nil, nil)
			body := rec.Body.String()
			if !strings.Contains(body, content+"\n\n") {
				t.Fatalf("provider content frame changed: %s", body)
			}
			if strings.Count(body, "data: [DONE]") != 1 || !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
				t.Fatal("terminal contract changed")
			}
			signatures := 0
			for _, event := range identityRegressionEvents(t, body) {
				if event["id"] != "native-response" || event["created"] != float64(123) {
					t.Fatalf("response envelope identity changed: %v", event)
				}
				if signature, ok := event["se_signature"]; ok {
					signatures++
					if signature != pr.SESignature || event["response_hash"] != pr.ResponseHash {
						t.Fatal("signature/hash changed")
					}
					metadata, ok := event["metadata"].(map[string]any)
					if !ok || metadata["job_id"] != pr.RequestID {
						t.Fatal("coordinator job identity changed")
					}
				}
			}
			if signatures != 1 {
				t.Fatalf("signature events=%d, want exactly one", signatures)
			}
		})
	}
}

func TestChatStreamErrorMetadataRetainsIdentity(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	pr := &registry.PendingRequest{RequestID: "coordinator-job", Model: "fixture-model", MetadataDetails: true,
		ResponseMetadata: json.RawMessage(`{"job_id":"coordinator-job"}`)}
	first := `data: {"id":"native-response","object":"chat.completion.chunk","created":123,"model":"fixture-model","choices":[{"index":0,"delta":{"content":"kept"}}]}`
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunkAndError(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr,
		[]string{first}, &protocol.InferenceErrorMessage{StatusCode: 500, Error: "fixture failure"})
	metadata := 0
	for _, event := range identityRegressionEvents(t, rec.Body.String()) {
		if _, ok := event["metadata"]; ok {
			metadata++
			if event["id"] != "native-response" || event["created"] != float64(123) {
				t.Fatal("error metadata switched response identity")
			}
		}
	}
	if metadata != 1 || strings.Contains(rec.Body.String(), "[DONE]") {
		t.Fatal("error terminal contract changed")
	}
}
