package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestNonStreamingChatMetadataDetails(t *testing.T) {
	ts, conn, pubKey := startChatMetadataTestServer(t, "meta-model")
	defer ts.Close()
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providerDone := make(chan struct{})
	go serveOneChatCompletion(t, ctx, conn, pubKey, providerDone, false)

	chatBody := `{"model":"meta-model","messages":[{"role":"user","content":"hi"}],"stream":false,"metadata_details":true}`
	httpReq, err := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatalf("decode response: %v\n%s", err, body)
	}
	meta, ok := result["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("expected metadata object, body = %s", body)
	}
	assertChatMetadataMatchesHeaders(t, resp.Header, meta)
	if strings.Contains(string(body), "serial") {
		t.Fatalf("body leaked a serial: %s", body)
	}
	if strings.Contains(string(body), "forged-provider") {
		t.Fatalf("body leaked provider-supplied metadata: %s", body)
	}
	<-providerDone
}

func TestNonStreamingChatMetadataDetailsHeader(t *testing.T) {
	ts, conn, pubKey := startChatMetadataTestServer(t, "meta-model")
	defer ts.Close()
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providerDone := make(chan struct{})
	go serveOneChatCompletion(t, ctx, conn, pubKey, providerDone, false)

	chatBody := `{"model":"meta-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, err := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	httpReq.Header.Set(metadataDetailsHeader, "true")
	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatalf("decode response: %v\n%s", err, body)
	}
	meta, ok := result["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("header opt-in expected metadata object, body = %s", body)
	}
	assertChatMetadataMatchesHeaders(t, resp.Header, meta)
	if strings.Contains(string(body), "forged-provider") {
		t.Fatalf("body leaked provider-supplied metadata: %s", body)
	}
	<-providerDone
}

func TestNonStreamingChatOmitsMetadataByDefault(t *testing.T) {
	ts, conn, pubKey := startChatMetadataTestServer(t, "meta-model")
	defer ts.Close()
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providerDone := make(chan struct{})
	go serveOneChatCompletion(t, ctx, conn, pubKey, providerDone, false)

	chatBody := `{"model":"meta-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, err := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	if strings.Contains(strings.ToLower(string(body)), `"metadata"`) {
		t.Fatalf("default response must not include metadata: %s", body)
	}
	if strings.Contains(string(body), "forged-provider") {
		t.Fatalf("default response leaked provider-supplied metadata: %s", body)
	}
	if resp.Header.Get("X-Provider-Trust-Level") == "" {
		t.Fatal("headers must still carry provider details when the body flag is off")
	}
	<-providerDone
}

func TestStreamingChatMetadataDetailsOnTerminalChunk(t *testing.T) {
	ts, conn, pubKey := startChatMetadataTestServer(t, "meta-model")
	defer ts.Close()
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	providerDone := make(chan struct{})
	go serveOneChatCompletion(t, ctx, conn, pubKey, providerDone, true)

	chatBody := `{"model":"meta-model","messages":[{"role":"user","content":"hi"}],"stream":true,"metadata_details":true}`
	httpReq, err := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	if strings.Contains(string(body), "forged-provider") {
		t.Fatalf("stream leaked provider-supplied metadata: %s", body)
	}

	events := parseSSEDataLines(string(body))
	if len(events) == 0 {
		t.Fatalf("no SSE events: %s", body)
	}
	var metaEvents int
	for i, event := range events {
		if strings.Contains(event, `"metadata"`) {
			metaEvents++
			if i == 0 && strings.Contains(event, `"content":"Hello"`) {
				t.Fatal("metadata must not ride the first content delta")
			}
		}
	}
	if metaEvents != 1 {
		t.Fatalf("expected metadata on exactly one SSE event, got %d\n%s", metaEvents, body)
	}
	last := events[len(events)-1]
	var obj map[string]any
	if err := json.Unmarshal([]byte(last), &obj); err != nil {
		t.Fatalf("decode last event %q: %v", last, err)
	}
	meta, ok := obj["metadata"].(map[string]any)
	if !ok {
		t.Fatalf("last event missing metadata: %s", last)
	}
	assertChatMetadataMatchesHeaders(t, resp.Header, meta)
	<-providerDone
}

func TestStreamingChatMetadataDetailsHeaderOptIn(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
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
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil)
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
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
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
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil)
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
			srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
			pr := &registry.PendingRequest{
				RequestID:        "job-meta",
				Model:            "gpt-oss-20b",
				MetadataDetails:  tc.metadataDetails,
				ResponseMetadata: tc.responseMeta,
			}
			firstChunks := []string{
				`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hi"}}],"Metadata":{"provider_id":"forged"}}`,
			}
			initialError := protocol.InferenceErrorMessage{Error: "backend failed", StatusCode: http.StatusInternalServerError}

			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			rec := httptest.NewRecorder()
			srv.handleStreamingResponseWithFirstChunkAndError(
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
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
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
	srv.handleStreamingResponseWithFirstChunk(
		rec,
		req,
		pr,
		[]string{`data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"hi"}}]}`},
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

func TestStripSSEDoneEventsPreservesSiblingEvents(t *testing.T) {
	t.Parallel()
	input := "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" +
		"event: done\nid: provider-terminal\ndata: [DONE]\n\n"

	got, removed := stripSSEDoneEvents(input)
	if !removed {
		t.Fatal("expected provider terminator to be removed")
	}
	if strings.Contains(got, "[DONE]") || strings.Contains(got, "provider-terminal") {
		t.Fatalf("provider terminator survived: %s", got)
	}
	if !strings.Contains(got, `"content":"hi"`) {
		t.Fatalf("sibling content event was removed: %s", got)
	}

	got, removed = stripSSEDoneEvents("\uFEFFdata: [DONE]\n\n")
	if !removed || strings.TrimSpace(got) != "" {
		t.Fatalf("BOM-prefixed provider terminator survived: %q", got)
	}
}

func startChatMetadataTestServer(t *testing.T, model string) (*httptest.Server, *websocket.Conn, string) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac16,7",
			ChipName:     "Apple M4 Max",
			MemoryGB:     64,
		},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
		if p := reg.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.Location = &store.ProviderLocation{
				City:        "Austin",
				Region:      "Texas",
				RegionCode:  "TX",
				Country:     "United States",
				CountryCode: "US",
				Latitude:    30.2672,
				Longitude:   -97.7431,
				Timezone:    "America/Chicago",
				Source:      "ip-api-pro",
			}
			p.Mu().Unlock()
		}
	}
	return ts, conn, pubKey
}

func serveOneChatCompletion(t *testing.T, ctx context.Context, conn *websocket.Conn, pubKey string, done chan struct{}, stream bool) {
	t.Helper()
	defer close(done)
	var inferReq protocol.InferenceRequestMessage
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Errorf("provider read: %v", err)
			return
		}
		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err == nil {
			msgType, _ := raw["type"].(string)
			if msgType == protocol.TypeAttestationChallenge {
				respData := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, respData)
				continue
			}
			if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeTrustStatus {
				continue
			}
		}
		if err := json.Unmarshal(data, &inferReq); err != nil {
			t.Errorf("unmarshal inference request: %v", err)
			return
		}
		break
	}
	if stream {
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}],"Metadata":{"provider_id":"forged-provider","provider_attested":false}}`+"\n\n")
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"METADATA":{"provider_id":"forged-provider"}}`+"\n\n")
	} else {
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","object":"chat.completion","created":1700000000,"model":"meta-model","choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"MeTaDaTa":{"provider_id":"forged-provider","provider_attested":false}}`+"\n\n")
	}
	complete := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: inferReq.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1},
	}
	completeData, _ := json.Marshal(complete)
	conn.Write(ctx, websocket.MessageText, completeData)
}

func assertChatMetadataMatchesHeaders(t *testing.T, header http.Header, meta map[string]any) {
	t.Helper()
	if got, _ := meta["provider_id"].(string); got == "" || got != header.Get("X-Provider-Id") {
		t.Errorf("provider_id = %v, header = %q", meta["provider_id"], header.Get("X-Provider-Id"))
	}
	if got, _ := meta["provider_trust_level"].(string); got != header.Get("X-Provider-Trust-Level") {
		t.Errorf("provider_trust_level = %v, header = %q", meta["provider_trust_level"], header.Get("X-Provider-Trust-Level"))
	}
	if got, _ := meta["provider_chip"].(string); got != header.Get("X-Provider-Chip") {
		t.Errorf("provider_chip = %v, header = %q", meta["provider_chip"], header.Get("X-Provider-Chip"))
	}
	if got, _ := meta["provider_machine_model"].(string); got != header.Get("X-Provider-Model") {
		t.Errorf("provider_machine_model = %v, header = %q", meta["provider_machine_model"], header.Get("X-Provider-Model"))
	}
	wantAttested := header.Get("X-Provider-Attested") == "true"
	if got, _ := meta["provider_attested"].(bool); got != wantAttested {
		t.Errorf("provider_attested = %v, header = %q", meta["provider_attested"], header.Get("X-Provider-Attested"))
	}
	if _, ok := meta["timing"].(map[string]any); !ok {
		t.Errorf("metadata.timing missing: %#v", meta)
	}
	if got, _ := meta["job_id"].(string); got == "" || got != header.Get("X-Inference-Job-ID") {
		t.Errorf("job_id = %v, header = %q", meta["job_id"], header.Get("X-Inference-Job-ID"))
	}
	loc, _ := meta["location"].(map[string]any)
	if loc == nil {
		t.Fatal("metadata.location missing")
	}
	if _, ok := loc["city"]; ok {
		t.Errorf("location must not include city: %#v", loc)
	}
	if got, _ := loc["region"].(string); got != "Texas" {
		t.Errorf("location.region = %v, want Texas", loc["region"])
	}
	if got, _ := loc["country_code"].(string); got != "US" {
		t.Errorf("location.country_code = %v, want US", loc["country_code"])
	}
	if _, ok := loc["latitude"]; ok {
		t.Errorf("location must not include latitude: %#v", loc)
	}
	if _, ok := loc["longitude"]; ok {
		t.Errorf("location must not include longitude: %#v", loc)
	}
	if _, ok := loc["accuracy_radius_km"]; ok {
		t.Errorf("location must not include accuracy radius: %#v", loc)
	}
	if _, ok := loc["source"]; ok {
		t.Errorf("location must not include lookup source: %#v", loc)
	}
	if _, ok := loc["updated_at"]; ok {
		t.Errorf("location must not include lookup timestamp: %#v", loc)
	}
}

func parseSSEDataLines(body string) []string {
	var events []string
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "[DONE]" || payload == "" {
			continue
		}
		events = append(events, payload)
	}
	return events
}
