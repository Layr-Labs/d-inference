package api

// Gated end-to-end performance measurement for the inference hot path.
//
// Real HTTP server (httptest), real WebSocket providers (in-process fakes that
// answer attestation challenges and stream encrypted chunks), real memory store,
// real API key → user → billing-free path. Everything the coordinator does per
// request runs — auth, parse, admission, routing, dispatch, relay, settlement —
// with providers that answer instantly, so the numbers are coordinator overhead.
//
//	EIGENINFERENCE_PERF_E2E=1 go test ./api/ -run TestPerfE2E -v -count=1
//
// Knobs (env): PERF_E2E_PROVIDERS (100), PERF_E2E_REQUESTS (400),
// PERF_E2E_CONCURRENCY (16), PERF_E2E_BODY_KB (16), PERF_E2E_CHUNKS (40).
// Skipped unless EIGENINFERENCE_PERF_E2E=1 so CI never runs it.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func perfEnvInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

type perfSample struct {
	ttfb  time.Duration
	total time.Duration
	code  int
}

func perfPercentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(float64(len(sorted)-1) * p)
	return sorted[idx]
}

// perfChatBody builds a multi-turn chat body of roughly kb kilobytes.
func perfChatBody(model string, kb int) string {
	turn := strings.Repeat("The quick brown fox jumps over the lazy dog. ", 12) // ~540 bytes
	var sb strings.Builder
	sb.WriteString(`{"model":`)
	sb.WriteString(strconv.Quote(model))
	sb.WriteString(`,"stream":true,"max_tokens":64,"messages":[{"role":"system","content":"You are terse."}`)
	for sb.Len() < kb*1024 {
		sb.WriteString(`,{"role":"user","content":`)
		sb.WriteString(strconv.Quote(turn))
		sb.WriteString(`},{"role":"assistant","content":`)
		sb.WriteString(strconv.Quote(turn))
		sb.WriteString(`}`)
	}
	sb.WriteString(`,{"role":"user","content":"Reply with one word."}]}`)
	return sb.String()
}

// runPerfProviderLoop answers challenges and serves each inference request with
// chunks encrypted SSE chunks followed by a completion. Returns served count.
func runPerfProviderLoop(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey, model string, chunks int) int {
	served := 0
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return served
		}
		var env struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(data, &env) != nil {
			continue
		}
		switch env.Type {
		case protocol.TypeAttestationChallenge:
			if err := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey)); err != nil {
				return served
			}
		case protocol.TypeInferenceRequest:
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				continue
			}
			for i := 0; i < chunks; i++ {
				sse := fmt.Sprintf(`data: {"id":"chatcmpl-perf","object":"chat.completion.chunk","model":%q,"choices":[{"index":0,"delta":{"content":"tok%d "},"finish_reason":null}]}`+"\n\n", model, i)
				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, sse)
			}
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 400, CompletionTokens: chunks},
			}
			completeData, _ := json.Marshal(complete)
			if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
				return served
			}
			served++
		}
	}
}

func TestPerfE2E_ChatCompletions(t *testing.T) {
	if os.Getenv("EIGENINFERENCE_PERF_E2E") != "1" {
		t.Skip("set EIGENINFERENCE_PERF_E2E=1 to run the end-to-end performance measurement")
	}
	providers := perfEnvInt("PERF_E2E_PROVIDERS", 100)
	requests := perfEnvInt("PERF_E2E_REQUESTS", 400)
	concurrency := perfEnvInt("PERF_E2E_CONCURRENCY", 16)
	bodyKB := perfEnvInt("PERF_E2E_BODY_KB", 16)
	chunks := perfEnvInt("PERF_E2E_CHUNKS", 40)

	ts, reg, st := setupLoadTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// A real user + API key so requireAuth takes the key → user path.
	if err := st.CreateUser(&store.User{AccountID: "perf-acct", PrivyUserID: "did:privy:perf"}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	apiKey, _, err := st.CreateAPIKey("perf-acct", store.APIKeyCreate{Name: "perf"})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	const model = "perf-model-4bit"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"

	providerCtx, providerCancel := context.WithCancel(ctx)
	defer providerCancel()
	var served atomic.Int64
	var providerWg sync.WaitGroup
	for i := 0; i < providers; i++ {
		pk := testPublicKeyB64()
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("dial provider %d: %v", i, err)
		}
		defer conn.Close(websocket.StatusNormalClosure, "done")
		regMsg := protocol.RegisterMessage{
			Type: protocol.TypeRegister,
			Hardware: protocol.Hardware{
				MachineModel: "Mac15,8", ChipName: "Apple M3 Max", ChipFamily: "M3", ChipTier: "Max",
				MemoryGB: 64, MemoryBandwidthGBs: 400,
				CPUCores: protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4}, GPUCores: 40,
			},
			Models:                  models,
			Backend:                 "mlx-swift",
			Version:                 "0.8.15",
			PublicKey:               pk,
			EncryptedResponseChunks: true,
			DecodeTPS:               float64(20 + i%25),
			PrivacyCapabilities:     testPrivacyCaps(),
		}
		regData, _ := json.Marshal(regMsg)
		if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
			t.Fatalf("register provider %d: %v", i, err)
		}
		hb := protocol.HeartbeatMessage{
			Type: protocol.TypeHeartbeat, Status: "idle",
			SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.2, CPUUsage: 0.1, ThermalState: "nominal"},
			BackendCapacity: &protocol.BackendCapacity{
				TotalMemoryGB: 64,
				Slots: []protocol.BackendSlotCapacity{{
					Model: model, State: "running", MaxConcurrency: 8,
					ObservedDecodeTPS: 25, ObservedPrefillTPS: 900,
					ActiveTokenBudgetMax: 120000, KVBytesPerToken: 98304,
				}},
			},
		}
		hbData, _ := json.Marshal(hb)
		if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
			t.Fatalf("heartbeat provider %d: %v", i, err)
		}
		providerWg.Add(1)
		go func() {
			defer providerWg.Done()
			served.Add(int64(runPerfProviderLoop(providerCtx, t, conn, pk, model, chunks)))
		}()
	}
	deadline := time.Now().Add(30 * time.Second)
	for reg.OnlineCount() < int64(providers) {
		if time.Now().After(deadline) {
			t.Fatalf("only %d/%d providers online", reg.OnlineCount(), providers)
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	body := perfChatBody(model, bodyKB)
	client := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: concurrency * 2}}
	samples := make([]perfSample, requests)
	var wg sync.WaitGroup
	sem := make(chan struct{}, concurrency)
	start := time.Now()
	for i := 0; i < requests; i++ {
		sem <- struct{}{}
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }()
			reqStart := time.Now()
			req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+apiKey)
			req.Header.Set("Content-Type", "application/json")
			resp, err := client.Do(req)
			if err != nil {
				samples[idx] = perfSample{code: 0, total: time.Since(reqStart)}
				return
			}
			defer resp.Body.Close()
			r := bufio.NewReader(resp.Body)
			ttfb := time.Duration(0)
			for {
				line, err := r.ReadString('\n')
				if ttfb == 0 && len(strings.TrimSpace(line)) > 0 {
					ttfb = time.Since(reqStart)
				}
				if err != nil {
					break
				}
			}
			samples[idx] = perfSample{code: resp.StatusCode, ttfb: ttfb, total: time.Since(reqStart)}
		}(i)
	}
	wg.Wait()
	elapsed := time.Since(start)

	codes := map[int]int{}
	var ttfbs, totals []time.Duration
	for _, s := range samples {
		codes[s.code]++
		if s.code == http.StatusOK {
			ttfbs = append(ttfbs, s.ttfb)
			totals = append(totals, s.total)
		}
	}
	sort.Slice(ttfbs, func(i, j int) bool { return ttfbs[i] < ttfbs[j] })
	sort.Slice(totals, func(i, j int) bool { return totals[i] < totals[j] })

	t.Logf("perf e2e: providers=%d requests=%d concurrency=%d body=%dKB chunks=%d", providers, requests, concurrency, bodyKB, chunks)
	t.Logf("perf e2e: elapsed=%s throughput=%.1f req/s codes=%v", elapsed.Round(time.Millisecond), float64(requests)/elapsed.Seconds(), codes)
	t.Logf("perf e2e: ttfb  p50=%s p95=%s p99=%s max=%s",
		perfPercentile(ttfbs, 0.50).Round(time.Microsecond), perfPercentile(ttfbs, 0.95).Round(time.Microsecond),
		perfPercentile(ttfbs, 0.99).Round(time.Microsecond), perfPercentile(ttfbs, 1).Round(time.Microsecond))
	t.Logf("perf e2e: total p50=%s p95=%s p99=%s max=%s",
		perfPercentile(totals, 0.50).Round(time.Microsecond), perfPercentile(totals, 0.95).Round(time.Microsecond),
		perfPercentile(totals, 0.99).Round(time.Microsecond), perfPercentile(totals, 1).Round(time.Microsecond))

	providerCancel()
	if codes[http.StatusOK] != requests {
		t.Fatalf("expected every request to succeed, got %v", codes)
	}
}
