package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const systemOneTestBody = `{"model":"laya","state":{"z":"urgent","a":42},"questions":{"triage":{"type":"choice","instructions":"Choose urgency","criteria":{"urgent":"Act now","normal":null}}}}`
const systemOneTestResponse = `{"model":"laya","answers":{"triage":{"type":"choice","choice":"urgent","probabilities":{"urgent":0.9,"normal":0.1},"confidence":0.8,"action":{"act_probability":0.95}}},"usage":{"input_tokens":999,"output_tokens":999}}`

func TestSystemOneRouteAuthDrainValidation(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "laya", SystemOne: true}, {ID: "chat"}})
	tests := []struct {
		name, body, auth string
		code             int
	}{
		{"unauthenticated", systemOneTestBody, "", 401},
		{"bad key", systemOneTestBody, "Bearer bad", 401},
		{"invalid json", "{", "Bearer test-key", 400},
		{"missing model", `{"state":"x","questions":{}}`, "Bearer test-key", 400},
		{"invalid state", strings.Replace(systemOneTestBody, `{"z":"urgent","a":42}`, `true`, 1), "Bearer test-key", 422},
		{"streaming", strings.Replace(systemOneTestBody, `"model":`, `"stream":true,"model":`, 1), "Bearer test-key", 422},
		{"generation params", strings.Replace(systemOneTestBody, `"model":`, `"max_tokens":1,"model":`, 1), "Bearer test-key", 422},
		{"wrong model family", strings.Replace(systemOneTestBody, `"laya"`, `"chat"`, 1), "Bearer test-key", 422},
		{"no native provider", systemOneTestBody, "Bearer test-key", 503},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			w := doReq(srv, http.MethodPost, systemOneEndpoint, tc.auth, tc.body)
			if w.Code != tc.code {
				t.Fatalf("got %d want %d: %s", w.Code, tc.code, w.Body.String())
			}
		})
	}
	for _, path := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		body := `{"model":"laya","messages":[{"role":"user","content":"x"}],"prompt":"x"}`
		w := doReq(srv, http.MethodPost, path, "Bearer test-key", body)
		if w.Code != 422 || !strings.Contains(w.Body.String(), systemOneEndpoint) {
			t.Fatalf("%s accepted native model: %d %s", path, w.Code, w.Body.String())
		}
	}
	srv.SetDraining(true)
	if w := doReq(srv, http.MethodPost, systemOneEndpoint, "Bearer test-key", systemOneTestBody); w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatalf("drain status %d: %s", w.Code, w.Body.String())
	}
}

func TestSystemOneRequestShapesAndOrdering(t *testing.T) {
	for _, question := range []string{
		`{"type":"noul","instructions":{"question":"Urgent?"},"criteria":{"true":"yes","false":"no"}}`,
		`{"type":"score","instructions":["Urgency"],"criteria":["low",{"description":"high"}]}`,
		`{"type":"choice","instructions":"Route?","criteria":{"z":null,"a":["other"]}}`,
	} {
		var parsed map[string]any
		body := `{"model":"laya","state":[],"questions":{"q":` + question + `}}`
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		if n, err := validateSystemOneRequest(parsed); err != nil || n != 1 {
			t.Fatalf("valid request rejected: %d %v", n, err)
		}
	}
	body, err := systemOneProviderBody([]byte(systemOneTestBody), "laya-build")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(body, []byte(`"state":{"z":"urgent","a":42}`)) || !bytes.Contains(body, []byte(`"criteria":{"urgent":"Act now","normal":null}`)) {
		t.Fatalf("ordering changed: %s", body)
	}
	if !bytes.Contains(body, []byte(`"endpoint":"/v1/systemone"`)) || !bytes.Contains(body, []byte(`"model":"laya-build"`)) {
		t.Fatalf("native routing fields missing: %s", body)
	}
}

func TestSystemOneRateLimitAndSealedTransport(t *testing.T) {
	srv, _ := testServer(t)
	srv.rateLimiter = ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1})
	doReq(srv, "POST", systemOneEndpoint, "Bearer test-key", `{`)
	if w := doReq(srv, "POST", systemOneEndpoint, "Bearer test-key", `{`); w.Code != 429 {
		t.Fatalf("rate limit %d %s", w.Code, w.Body.String())
	}
	srv.rateLimiter = nil
	key, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
	if err != nil {
		t.Fatal(err)
	}
	srv.SetCoordinatorKey(key)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "laya", SystemOne: true}})
	sealed, _, private := sealRequest(t, []byte(systemOneTestBody), key.PublicKey, key.KID)
	req := httptest.NewRequest("POST", systemOneEndpoint, bytes.NewReader(sealed))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", SealedContentType)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	// Successful unsealing reaches the native no-provider fence.
	if w.Code != 503 {
		t.Fatalf("sealed route %d %s", w.Code, w.Body.String())
	}
	plaintext := unsealResponse(t, w.Body.Bytes(), key.PublicKey, private)
	if !bytes.Contains(plaintext, []byte("native SystemOne")) {
		t.Fatalf("did not reach native handler: %s", plaintext)
	}
}

func TestSystemOneEncryptedDispatchPreservesNativeResponseAndUsage(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "laya", SystemOne: true}})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "native", AuthToken: "test-key", Version: "0.9.7", DecodeTPS: 100, Models: []failoverModelSpec{{ID: "laya", ModelType: "laya", SystemOne: true}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if !bytes.Contains(body, []byte(`"endpoint":"/v1/systemone"`)) || bytes.Contains(body, []byte(`"max_tokens"`)) || !bytes.Contains(body, []byte(`"criteria":{"urgent":"Act now","normal":null}`)) {
			t.Errorf("native payload altered: %s", body)
		}
		p := reg.GetProvider(fp.registryID)
		pending := p.GetPending(req.RequestID)
		if pending == nil || !pending.Traits.SystemOne || pending.RequestedMaxTokens != 0 {
			t.Errorf("native traits/output budget lost: %+v", pending)
		}
		writeEncryptedTestChunk(t, ctx, fp.conn, req, fp.pubKey, systemOneTestResponse)
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 73, CompletionTokens: 0})
		// A duplicate terminal must not produce a second usage record.
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 73, CompletionTokens: 0})
	}})
	req, err := newAuthRequest(t, ctx, ts.URL+systemOneEndpoint, systemOneTestBody, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		t.Fatalf("status %d: %s", resp.StatusCode, raw)
	}
	var result map[string]any
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if result["choices"] != nil || result["answers"] == nil {
		t.Fatalf("native response became chat: %s", raw)
	}
	usage := result["usage"].(map[string]any)
	if usage["input_tokens"] != float64(73) || usage["output_tokens"] != float64(0) {
		t.Fatalf("untrusted raw usage was not replaced: %s", raw)
	}
	if !bytes.Contains(raw, []byte(`"act_probability":0.95`)) {
		t.Fatalf("action head lost: %s", raw)
	}
	if fp.dispatches.Load() != 1 {
		t.Fatalf("dispatches %d", fp.dispatches.Load())
	}
	records := st.UsageByConsumer(testConsumerID)
	if len(records) != 1 || records[0].PromptTokens != 73 || records[0].CompletionTokens != 0 || records[0].CostMicroUSD <= 0 {
		t.Fatalf("usage records %+v", records)
	}
}

func TestSystemOneCatalogRegistrationAndDiscovery(t *testing.T) {
	req := registerModelRequest{ModelID: "laya", Version: "v1", Architecture: "laya", Capabilities: []string{"system_one"}, Quantization: "bf16", MaxContextLength: 512, MaxOutputLength: 0, MinRAMGB: 8, InputPrice: 100, OutputPrice: 0}
	if err := validateRegisterModelRequest(req); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*registerModelRequest){func(r *registerModelRequest) { r.MaxOutputLength = 1 }, func(r *registerModelRequest) { r.OutputPrice = 1 }, func(r *registerModelRequest) { r.Capabilities = []string{"chat"} }, func(r *registerModelRequest) { r.Architecture = "llama" }} {
		invalid := req
		mutate(&invalid)
		if err := validateRegisterModelRequest(invalid); err == nil {
			t.Fatalf("accepted invalid native registration: %+v", invalid)
		}
	}
	srv, _ := testServer(t)
	entry := store.ModelRegistryEntry{ID: "laya", Architecture: "laya", Capabilities: []string{"system_one"}, MaxContextLength: 512}
	fields := srv.openRouterModelFieldsFor("laya", "bf16", entry, true)
	if len(fields.SupportedSamplingParameters) != 0 || len(fields.SupportedFeatures) != 1 || fields.SupportedFeatures[0] != "system_one" {
		t.Fatalf("generation metadata leaked: %+v", fields)
	}
	rec := &store.ModelRegistryRecord{ModelRegistryEntry: entry}
	if supportedModelFromRegistryRecord(rec).ModelType != "laya" || !isNonTextModelType("laya") {
		t.Fatal("native catalog family lost")
	}
}

func TestSystemOneBodyLimit(t *testing.T) {
	srv, _ := testServer(t)
	body := `{"model":"laya","state":"` + strings.Repeat("x", maxSystemOneBodyBytes) + `","questions":{"q":{"type":"noul","instructions":"x"}}}`
	w := doReq(srv, "POST", systemOneEndpoint, "Bearer test-key", body)
	if w.Code != 413 || !strings.Contains(w.Body.String(), "1048576-byte") {
		t.Fatalf("native body cap: %d %s", w.Code, w.Body.String())
	}
}

func TestSystemOneNativeHeartbeatPassesHardPredictionGate(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "laya", SystemOne: true}})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	questions := map[string]any{}
	answers := map[string]any{}
	for i := 0; i < 64; i++ {
		key := fmt.Sprint(i)
		questions[key] = map[string]any{"type": "noul", "instructions": "urgent?"}
		answers[key] = map[string]any{"type": "noul", "noul": 0.5, "confidence": 0.5, "action": map[string]any{"act_probability": 0.5}}
	}
	response, _ := json.Marshal(map[string]any{"model": "laya", "answers": answers})
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "native-capacity", AuthToken: "test-key", Version: "0.9.7", DecodeTPS: 0, Models: []failoverModelSpec{{ID: "laya", ModelType: "laya", SystemOne: true}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		pending := reg.GetProvider(fp.registryID).GetPending(req.RequestID)
		if pending == nil || pending.MaxTTFTMs != 0 || pending.FirstContentDeadline.IsZero() {
			t.Errorf("native predicted/actual deadline contract %+v", pending)
		}
		writeEncryptedTestChunk(t, ctx, fp.conn, req, fp.pubKey, string(response))
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 640, CompletionTokens: 0})
	}})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	p.DecodeTPS = 0
	p.PrefillTPS = 0
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: "laya", State: "idle", MaxConcurrency: 1, ActiveTokenBudgetMax: 32768, MaxTokensPotential: 0}}}
	p.Mu().Unlock()
	body, _ := json.Marshal(map[string]any{"model": "laya", "state": "x", "questions": questions})
	req, err := newAuthRequest(t, ctx, ts.URL+systemOneEndpoint, string(body), "test-key")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		t.Fatalf("native full request incorrectly hard-rejected: %d %s", resp.StatusCode, raw)
	}
}

func TestSystemOneCacheAttemptPreservesBodyAtNativeLimit(t *testing.T) {
	raw, err := systemOneProviderBody([]byte(systemOneTestBody), "laya")
	if err != nil {
		t.Fatal(err)
	}
	// Whitespace fills the valid native JSON body exactly to its byte limit.
	raw = append(raw, bytes.Repeat([]byte(" "), maxSystemOneBodyBytes-len(raw))...)
	pr := &registry.PendingRequest{Traits: registry.RequestTraits{SystemOne: true}, LegacyCacheBustKey: "ignored-old-key"}
	provider := &registry.Provider{PrefixCacheProtocol: 0}
	body, err := bodyForCacheAttempt(raw, false, provider, pr)
	if err != nil || !bytes.Equal(body, raw) || len(body) != maxSystemOneBodyBytes {
		t.Fatalf("native cache path modified boundary body: %d %v", len(body), err)
	}
	if !bytes.Contains(body, []byte(`"state":{"z":"urgent","a":42}`)) || !bytes.Contains(body, []byte(`"criteria":{"urgent":"Act now","normal":null}`)) {
		t.Fatal("native nested ordering changed")
	}
	if _, err := bodyForCacheAttempt(append(raw, ' '), false, provider, pr); err == nil {
		t.Fatal("oversized final native body accepted")
	}
}
