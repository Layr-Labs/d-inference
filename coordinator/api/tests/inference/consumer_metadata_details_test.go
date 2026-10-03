package inference_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
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
	httpReq, err := testkit.NewAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
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
	httpReq, err := testkit.NewAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	httpReq.Header.Set(inreq.MetadataDetailsHeader, "true")
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
	httpReq, err := testkit.NewAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
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
	httpReq, err := testkit.NewAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
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

func startChatMetadataTestServer(t *testing.T, model string) (*httptest.Server, *websocket.Conn, string) {
	t.Helper()
	logger := quietLogger()
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	pubKey := testkit.PublicKeyB64()
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
		PrivacyCapabilities:     testkit.PrivacyCaps(),
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
				respData := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, respData)
				continue
			}
			if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeTrustStatus ||
				msgType == protocol.TypeDesiredModels {
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
		testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}],"Metadata":{"provider_id":"forged-provider","provider_attested":false}}`+"\n\n")
		testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"METADATA":{"provider_id":"forged-provider"}}`+"\n\n")
	} else {
		testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey,
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
