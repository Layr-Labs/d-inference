package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type deadlineAttemptBudget struct {
	provider  string
	wireMS    int64
	maxTTFTMS float64
}

type deadlineAttemptRecorder struct {
	mu       sync.Mutex
	attempts []deadlineAttemptBudget
}

func (r *deadlineAttemptRecorder) capture(
	t *testing.T,
	reg *registry.Registry,
	fp *failoverProvider,
	req protocol.InferenceRequestMessage,
) int {
	t.Helper()
	var maxTTFTMS float64
	provider := reg.GetProvider(fp.registryID)
	if provider == nil {
		t.Errorf("provider %q missing while capturing deadline budget", fp.name)
	} else if pending := provider.GetPending(req.RequestID); pending == nil {
		t.Errorf("pending request %q missing on provider %q", req.RequestID, fp.name)
	} else {
		maxTTFTMS = pending.MaxTTFTMs
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts = append(r.attempts, deadlineAttemptBudget{
		provider:  fp.name,
		wireMS:    req.FirstContentBudgetMS,
		maxTTFTMS: maxTTFTMS,
	})
	return len(r.attempts)
}

func (r *deadlineAttemptRecorder) snapshot() []deadlineAttemptBudget {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]deadlineAttemptBudget, len(r.attempts))
	copy(out, r.attempts)
	return out
}

func TestModelSpecificFirstContentDeadlineReachesProviderWire(t *testing.T) {
	tests := []struct {
		name      string
		model     string
		wantBase  time.Duration
		otherBase time.Duration
	}{
		{
			name:      "Bonsai custom token slope",
			model:     "ternary-bonsai-2-27b",
			wantBase:  9 * time.Second,
			otherBase: 4 * time.Second,
		},
		{
			name:      "ordinary production-like model",
			model:     "ordinary-wire-deadline-model",
			wantBase:  9 * time.Second,
			otherBase: 4 * time.Second,
		},
		{
			name:      "Qwen3-VL exact model",
			model:     modelpolicy.Qwen3VL30BA3BInstructModelID,
			wantBase:  4 * time.Second,
			otherBase: 9 * time.Second,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, api.ServerConfig{
				FirstContentDeadlineBase: 9 * time.Second,
			})
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			wireBudget := make(chan int64, 1)
			startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "provider-model-deadline", Version: "0.8.15", DecodeTPS: 200,
				Models: []failoverModelSpec{{ID: tt.model}},
				Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					if pending := reg.GetProvider(fp.registryID).GetPending(req.RequestID); pending != nil && tt.model == "ternary-bonsai-2-27b" {
						want := 9*time.Second + time.Duration(pending.EstimatedPromptTokens)*5*time.Millisecond
						if got := pending.FirstContentDeadline.Sub(pending.Timing.ReceivedAt); got != want {
							t.Errorf("Bonsai live clock %s, want %s", got, want)
						}
					}
					wireBudget <- req.FirstContentBudgetMS
					fp.serveFull(ctx, req, tt.model, markerFor(fp.name))
				},
			})

			requestBody := buildChatBody(t, tt.model, false, nil)
			var parsed map[string]any
			if err := json.Unmarshal([]byte(requestBody), &parsed); err != nil {
				t.Fatalf("parse request body: %v", err)
			}
			expected := srv.FirstContentDeadline(
				tt.model, inreq.EstimatePromptTokens(parsed),
			).Milliseconds()
			if expected < tt.wantBase.Milliseconds() ||
				expected >= tt.wantBase.Milliseconds()+time.Second.Milliseconds() {
				t.Fatalf("selected deadline = %dms, want %s base plus prompt slope", expected, tt.wantBase)
			}
			if expected >= tt.otherBase.Milliseconds() && tt.wantBase < tt.otherBase {
				t.Fatalf("selected deadline = %dms, looks like ordinary %s policy", expected, tt.otherBase)
			}

			status, body, err := postChat(ctx, ts.URL, "test-key", requestBody)
			if err != nil {
				t.Fatalf("chat request: %v", err)
			}
			if status != http.StatusOK {
				t.Fatalf("status=%d body=%s, want 200", status, body)
			}

			select {
			case got := <-wireBudget:
				// Writer dequeue refreshes the remaining budget, so it may only
				// decrease from the request-local duration selected above. Do not
				// impose a lower bound: a loaded CI host may delay writer handoff.
				if got <= 0 || got > expected {
					t.Fatalf("wire budget = %dms, want (0,%d]", got, expected)
				}
			case <-ctx.Done():
				t.Fatal("provider did not receive inference request")
			}
		})
	}
}

func postGenericInference(
	ctx context.Context,
	baseURL, endpoint, body string,
) (int, string, error) {
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost, baseURL+endpoint, strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data), err
}

func TestAcceptedDoesNotStopSpeculativeFirstContentRace(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServerWithConfig(t, api.ServerConfig{
		FirstContentDeadlineBase: 3 * time.Second,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "accepted-still-speculates"
	var attempts deadlineAttemptRecorder
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		if attempts.capture(t, reg, fp, req) == 1 {
			fp.sendAccepted(ctx, req)
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	primary := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "accepted-primary", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	backup := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "content-backup", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	reportIdleFirstContentEvidence(reg, primary.registryID, model)
	reportIdleFirstContentEvidence(reg, backup.registryID, model)

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	got := attempts.snapshot()
	if len(got) != 2 {
		t.Fatalf("dispatches = %+v, want accepted primary plus speculative backup", got)
	}
	assertCleanFailoverStream(t, status, body, markerFor(got[1].provider))
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	losers, winners, backups := 0, 0, 0
	for _, a := range outcome.Attempts {
		if a.Winning {
			winners++
		}
		if a.BackupOf != "" {
			backups++
		}
		if a.RawReason == "speculative_loser" {
			losers++
		}
	}
	if outcome.Termination != "completed" || winners != 1 || backups != 1 || losers != 1 {
		t.Fatalf("speculative accounting: %+v", outcome)
	}

}

func TestProductionConfigStreamingDeadlineExhaustionRetainsHTTP429(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		body     func(string) string
	}{
		{
			name:     "chat completions",
			endpoint: "/v1/chat/completions",
			body: func(model string) string {
				return buildChatBody(t, model, true, nil)
			},
		},
		{
			name:     "anthropic messages",
			endpoint: "/v1/messages",
			body: func(model string) string {
				return fmt.Sprintf(
					`{"model":%q,"stream":true,"messages":[{"role":"user","content":"hello"}],"max_tokens":16}`,
					model,
				)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, api.ServerConfig{
				FirstContentDeadlineBase: 600 * time.Millisecond,
			})
			srv.SetTTFTHardReject(true)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			model := "streaming-deadline-" + strings.ReplaceAll(test.name, " ", "-")
			script := func(
				ctx context.Context,
				_ *failoverProvider,
				_ protocol.InferenceRequestMessage,
				_ []byte,
			) {
				// Remain completely silent. The coordinator's request-absolute
				// clock—not a provider-authored refusal—must own the terminal.
				<-ctx.Done()
			}
			for i := 0; i < 2; i++ {
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: fmt.Sprintf("%s-provider-%d", model, i), Version: "0.8.10",
					DecodeTPS: 200 - float64(i),
					Models:    []failoverModelSpec{{ID: model}},
					Script:    script,
				})
			}

			status, body, err := postGenericInference(
				ctx, ts.URL, test.endpoint, test.body(model))
			if err != nil {
				t.Fatal(err)
			}
			if status != http.StatusTooManyRequests {
				t.Fatalf("status=%d body=%s, want terminal HTTP 429", status, body)
			}
			if !strings.Contains(body, "rate_limit_exceeded") {
				t.Fatalf("deadline rejection lost retryable body: %s", body)
			}
			if strings.Contains(body, "data:") ||
				strings.Contains(body, "event:") ||
				strings.Contains(body, ": keepalive") {
				t.Fatalf("pre-content rejection was committed as SSE: %s", body)
			}
		})
	}
}
