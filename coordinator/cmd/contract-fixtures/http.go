package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	apitypes "github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type httpRequestContract struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body,omitempty"`
}

type httpResponseContract struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body"`
}

type httpExchangeContract struct {
	Name     string               `json:"name"`
	Request  httpRequestContract  `json:"request"`
	Response httpResponseContract `json:"response"`
}

type httpShapeContract struct {
	Name        string `json:"name"`
	ContentType string `json:"content_type"`
	Body        string `json:"body"`
}

type httpContractFile struct {
	SchemaVersion  int                    `json:"schema_version"`
	Exchanges      []httpExchangeContract `json:"exchanges"`
	ResponseShapes []httpShapeContract    `json:"response_shapes"`
}

func generateHTTP(_ string) (map[string][]byte, error) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	memory := store.NewMemory(store.Config{AdminKey: "contract-admin-key"})
	fleet := registry.New(logger)
	server := api.NewServer(fleet, memory, api.ServerConfig{AdminKey: "contract-admin-key"}, logger)
	defer server.Close()
	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()

	specs := []httpRequestContract{
		{Method: http.MethodGet, Path: "/health"},
		{Method: http.MethodGet, Path: "/readyz"},
		{Method: http.MethodGet, Path: "/v1/encryption-key"},
		{Method: http.MethodGet, Path: "/v1/models"},
		{Method: http.MethodGet, Path: "/v1/models", Headers: map[string]string{"Authorization": "Bearer contract-admin-key"}},
		{Method: http.MethodPost, Path: "/v1/chat/completions", Headers: map[string]string{
			"Authorization": "Bearer contract-admin-key", "Content-Type": "application/json",
		}, Body: "{"},
		{Method: http.MethodPost, Path: "/v1/embeddings", Headers: map[string]string{
			"Authorization": "Bearer contract-admin-key", "Content-Type": "application/json",
		}, Body: `{"model":"model-a","input":"hello"}`},
	}
	names := []string{
		"health",
		"readiness",
		"encryption_key_unconfigured",
		"models_missing_auth",
		"models_empty",
		"chat_invalid_json",
		"unimplemented_endpoint",
	}
	exchanges := make([]httpExchangeContract, 0, len(specs))
	for index, spec := range specs {
		response, err := executeHTTPContract(httpServer.URL, spec)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", names[index], err)
		}
		exchanges = append(exchanges, httpExchangeContract{
			Name: names[index], Request: spec, Response: response,
		})
	}

	shapes, err := canonicalHTTPShapes()
	if err != nil {
		return nil, err
	}
	contract, err := json.MarshalIndent(httpContractFile{
		SchemaVersion:  1,
		Exchanges:      exchanges,
		ResponseShapes: shapes,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal HTTP contracts: %w", err)
	}
	return map[string][]byte{"tests/contracts/http/core.json": contract}, nil
}

func executeHTTPContract(baseURL string, contract httpRequestContract) (httpResponseContract, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, contract.Method, baseURL+contract.Path, strings.NewReader(contract.Body))
	if err != nil {
		return httpResponseContract{}, err
	}
	request.Header.Set("X-Request-ID", "contract-request-id")
	for name, value := range contract.Headers {
		request.Header.Set(name, value)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return httpResponseContract{}, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return httpResponseContract{}, err
	}
	body = canonicalJSON(body)
	headers := make(map[string]string)
	for _, name := range []string{"Content-Type", "Cache-Control", "Retry-After"} {
		if value := response.Header.Get(name); value != "" {
			headers[name] = value
		}
	}
	return httpResponseContract{
		Status: response.StatusCode, Headers: headers, Body: string(body),
	}, nil
}

func canonicalHTTPShapes() ([]httpShapeContract, error) {
	chat := apitypes.ChatCompletionResponse{
		ID: "chatcmpl-contract", Object: "chat.completion", Created: 1700000000, Model: "model-a",
		Choices: []apitypes.ChatCompletionChoice{{
			Index:        0,
			Message:      apitypes.ChatCompletionMessage{Role: "assistant", Content: "hello"},
			FinishReason: "stop",
		}},
		Usage:       apitypes.ChatCompletionUsage{PromptTokens: 2, CompletionTokens: 1, TotalTokens: 3},
		SESignature: "se-signature", ResponseHash: "response-sha256",
	}
	responses := apitypes.ResponsesResponse{
		ID: "resp_contract", Object: "response", CreatedAt: 1700000000, Status: "completed",
		Error: nil, IncompleteDetail: nil, Instructions: nil, MaxOutputTokens: nil,
		Model: "model-a", Output: []any{}, ParallelToolCalls: false,
		Temperature: nil, ToolChoice: nil, Tools: []any{}, TopP: nil,
		Metadata: map[string]any{},
		Usage: apitypes.ResponsesUsage{
			InputTokens: 2, InputTokensDetail: apitypes.ResponsesUsageDetail{},
			OutputTokens: 1, OutputTokensDetail: apitypes.ResponsesUsageDetail{},
		},
	}

	chatBody, err := json.Marshal(chat)
	if err != nil {
		return nil, fmt.Errorf("marshal chat shape: %w", err)
	}
	responsesBody, err := json.Marshal(responses)
	if err != nil {
		return nil, fmt.Errorf("marshal responses shape: %w", err)
	}
	stream := strings.Join([]string{
		`data: {"id":"chatcmpl-contract","object":"chat.completion.chunk","created":1700000000,"model":"model-a","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`,
		"",
		`data: {"id":"chatcmpl-contract","object":"chat.completion.chunk","created":1700000000,"model":"model-a","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"stop"}]}`,
		"",
		"data: [DONE]",
		"",
	}, "\n")
	return []httpShapeContract{
		{Name: "chat_non_streaming", ContentType: "application/json", Body: string(canonicalJSON(chatBody))},
		{Name: "responses_non_streaming", ContentType: "application/json", Body: string(canonicalJSON(responsesBody))},
		{Name: "chat_streaming_sse", ContentType: "text/event-stream", Body: stream},
	}, nil
}

func canonicalJSON(input []byte) []byte {
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return bytes.TrimSpace(input)
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return bytes.TrimSpace(input)
	}
	return canonical
}
