package inference_test

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
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

func waitForDeadlineTelemetry(
	t *testing.T,
	st *memory.MemoryStore,
	minRoutes, minRejections int,
) ([]store.InferenceRouteRecord, []store.RejectionRecord) {
	t.Helper()
	return waitForDeadlineTelemetryWhere(t, st, minRoutes, minRejections, nil)
}

// waitForDeadlineTelemetryWhere waits for the row counts AND, when given, for
// the route rows to satisfy settled. The route sink writes the attempt record
// and its outcome as separate batched statements, so a row can be visible
// before its final_status/error_reason are; callers that assert on outcome
// fields must wait for them explicitly.
func waitForDeadlineTelemetryWhere(
	t *testing.T,
	st *memory.MemoryStore,
	minRoutes, minRejections int,
	settled func(routes []store.InferenceRouteRecord) bool,
) ([]store.InferenceRouteRecord, []store.RejectionRecord) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		routes := st.InferenceRouteRecordsSince(time.Time{})
		rejections := st.RejectionRecordsSince(time.Time{})
		if len(routes) >= minRoutes && len(rejections) >= minRejections &&
			(settled == nil || settled(routes)) {
			return routes, rejections
		}
		if time.Now().After(deadline) {
			t.Fatalf(
				"telemetry did not settle: routes=%d/%d rejections=%d/%d",
				len(routes), minRoutes, len(rejections), minRejections)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func assertDeadlineRefusalDidNotFeedCapacity(
	t *testing.T,
	reg *registry.Registry,
	provider *failoverProvider,
	model string,
) {
	t.Helper()
	if provider == nil {
		t.Fatal("deadline refusal provider is nil")
	}
	if reg.CapacityCooldownActive(provider.registryID, model) {
		t.Errorf("provider %q deadline refusal fed capacity cooldown", provider.name)
	}
	if reg.BudgetClampActive(provider.registryID, model) {
		t.Errorf("provider %q deadline refusal armed budget clamp", provider.name)
	}
	if rate, samples := reg.CapacityRejectRate(provider.registryID, model); rate != 0 || samples != 0 {
		t.Errorf(
			"provider %q deadline refusal fed capacity rate: rate=%v samples=%d",
			provider.name, rate, samples)
	}
	p := reg.GetProvider(provider.registryID)
	if p == nil {
		t.Fatalf("provider %q disappeared before reputation assertion", provider.name)
	}
	p.Mu().Lock()
	failedJobs := p.Reputation.FailedJobs
	totalJobs := p.Reputation.TotalJobs
	p.Mu().Unlock()
	if failedJobs != 0 || totalJobs != 0 {
		t.Errorf(
			"provider %q deadline refusal changed reputation: failed=%d total=%d",
			provider.name, failedJobs, totalJobs)
	}
}

func assertAttemptBudgetsDecrease(t *testing.T, attempts []deadlineAttemptBudget) {
	t.Helper()
	if len(attempts) < 2 {
		t.Fatalf("captured %d attempts, want at least 2", len(attempts))
	}
	for i, attempt := range attempts {
		if attempt.wireMS <= 0 {
			t.Errorf("attempt %d provider %q wire budget = %d, want positive", i, attempt.provider, attempt.wireMS)
		}
		if attempt.maxTTFTMS <= 0 {
			t.Errorf("attempt %d provider %q MaxTTFTMs = %.3f, want positive", i, attempt.provider, attempt.maxTTFTMS)
		}
		if attempt.maxTTFTMS < float64(attempt.wireMS) {
			t.Errorf(
				"attempt %d provider %q MaxTTFTMs %.3f is below later wire budget %d",
				i, attempt.provider, attempt.maxTTFTMS, attempt.wireMS)
		}
		if i > 0 {
			if attempt.wireMS >= attempts[i-1].wireMS {
				t.Errorf(
					"wire budgets did not decrease: attempt %d=%d previous=%d",
					i, attempt.wireMS, attempts[i-1].wireMS)
			}
			if attempt.maxTTFTMS >= attempts[i-1].maxTTFTMS {
				t.Errorf(
					"hard-admission budgets did not decrease: attempt %d=%.3f previous=%.3f",
					i, attempt.maxTTFTMS, attempts[i-1].maxTTFTMS)
			}
		}
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
