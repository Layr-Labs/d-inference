package api

// DAR-347 dispatch-loop integration tests: oversized / capacity rejections must
// stop the failover loop early (uptime-neutral 429) instead of storming all 64
// providers, while genuine transient-capacity rejections still fail over. They
// reuse the failover harness (setupFailoverServer / startFailoverProvider /
// postChat) and drive the REAL dispatch loop through fake WS providers.

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// rejectScript makes every dispatch reject pre-content with (errMsg, status) and
// NO chunks — the shape of a provider token-budget admission rejection.
func rejectScript(errMsg string, status int) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendInferenceError(ctx, req, errMsg, status)
	}
}

// TestDispatch_DeterministicTokenBudget_StopsAfterOneAttempt: a request whose
// prompt exceeds the model context is rejected identically by every provider
// ("request exceeds batch token budget"). The loop MUST stop after the first
// attempt and return an uptime-neutral 429 + Retry-After — not retry across the
// fleet (the prod storm: median 22 / max 63 attempts). Two providers are present
// so a storm would be observable as >1 dispatch.
func TestDispatch_DeterministicTokenBudget_StopsAfterOneAttempt(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "oversized-deterministic-model"
	script := rejectScript("token_budget_exhausted: request exceeds batch token budget", http.StatusServiceUnavailable)
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	// Inline request so we can assert the Retry-After header.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
		strings.NewReader(buildChatBody(t, model, false, nil)))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(resp.Body)
	body := string(bodyBytes)

	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (deterministic unservable → uptime-neutral 429); body=%s", resp.StatusCode, body)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Errorf("missing Retry-After header on the 429")
	}
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", body)
	}
	if total := pA.dispatchCount() + pB.dispatchCount(); total != 1 {
		t.Errorf("total dispatches = %d, want 1 — a deterministic context rejection must STOP after the first attempt, not storm", total)
	}
}

// TestDispatch_TransientCapacity_StillFailsOver: a provider-specific transient
// shortage ("queue full") must NOT stop the loop — another provider may serve it.
// Guards against over-rejection (the false-NO / underutilization direction).
func TestDispatch_TransientCapacity_StillFailsOver(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "transient-capacity-model"
	rec := &dispatchRecorder{}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if rec.record(fp.name) == 1 {
			// First-dispatched provider: transient capacity shortage.
			fp.sendInferenceError(ctx, req, "request rejected: queue full", http.StatusServiceUnavailable)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want 2 (transient capacity must fail over to a second provider); status=%d body=%s", seq, status, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry on a DIFFERENT provider", seq[0])
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
}

// TestDispatch_TransientCapacity_CappedRetries: when EVERY provider returns a
// transient capacity shortage, the loop must stop at maxCapacityClassRetries (not
// walk all maxDispatchAttempts=64). Five providers are present so the cap — not
// candidate exhaustion — is what stops it.
func TestDispatch_TransientCapacity_CappedRetries(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "transient-capped-model"
	script := rejectScript("server busy", http.StatusServiceUnavailable)
	const nProviders = 5
	providers := make([]*failoverProvider, 0, nProviders)
	for i := 0; i < nProviders; i++ {
		providers = append(providers, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("provider-%d", i), Version: "0.6.20", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		}))
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", status, body)
	}
	total := 0
	for _, p := range providers {
		total += p.dispatchCount()
	}
	if total != maxCapacityClassRetries {
		t.Errorf("total dispatches = %d, want %d (transient capacity must be capped, not stormed to %d)",
			total, maxCapacityClassRetries, maxDispatchAttempts)
	}
}
