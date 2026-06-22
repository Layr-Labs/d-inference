package api

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newTTFTTestServer(t *testing.T) *Server {
	t.Helper()
	return NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{}, quietLogger())
}

// counterMatches reports whether the in-process metrics registry holds a counter
// whose key starts with name, contains every sub, and has a positive value.
func counterMatches(counters map[string]int64, name string, subs ...string) bool {
	for k, v := range counters {
		if v < 1 || !strings.HasPrefix(k, name) {
			continue
		}
		ok := true
		for _, s := range subs {
			if !strings.Contains(k, s) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// TestEmitTTFTShadowMetrics asserts the shadow admission/spread counters are
// emitted with the right tags for a would_shed + would_redirect decision.
func TestEmitTTFTShadowMetrics(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitTTFTShadowMetrics("gpt-oss-20b", registry.RoutingDecision{
		ProviderID:                  "p1",
		ShadowEvaluated:             true,
		ShadowMode:                  "shadow",
		ShadowWouldShed:             true,
		ShadowIdleAlternativeExists: true,
		ShadowEstimateMs:            14000,
		ShadowDeadlineMs:            11000,
		ShadowOccupancy:             5,
	})
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.ttft_admission", "decision=would_shed", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.ttft_admission{would_shed}; counters=%v", counters)
	}
	if !counterMatches(counters, "routing.ttft_spread", "would_redirect_to_idle=true", "model=gpt-oss-20b") {
		t.Fatalf("missing routing.ttft_spread{redirect=true}; counters=%v", counters)
	}
}

// TestEmitTTFTShadowMetricsServeAndNoRedirect covers the negative tag values.
func TestEmitTTFTShadowMetricsServeAndNoRedirect(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitTTFTShadowMetrics("gpt-oss-20b", registry.RoutingDecision{
		ShadowEvaluated: true,
		ShadowMode:      "shadow",
	})
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.ttft_admission", "decision=would_serve") {
		t.Fatalf("missing routing.ttft_admission{would_serve}; counters=%v", counters)
	}
	if !counterMatches(counters, "routing.ttft_spread", "would_redirect_to_idle=false") {
		t.Fatalf("missing routing.ttft_spread{redirect=false}; counters=%v", counters)
	}
}

// TestEmitTTFTShadowMetricsNoopWhenNotEvaluated is the behavior-neutral default:
// no shadow metrics when admission mode was off (ShadowEvaluated=false).
func TestEmitTTFTShadowMetricsNoopWhenNotEvaluated(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitTTFTShadowMetrics("gpt-oss-20b", registry.RoutingDecision{ShadowEvaluated: false})
	if got := len(srv.metrics.Snapshot().Counters); got != 0 {
		t.Fatalf("no shadow metrics expected when not evaluated, got %d counters", got)
	}
}

// TestActualTTFTUsesFirstContentNotPreamble pins the corrected semantics:
// actual_ttft_ms comes from FirstContentAt (delivered content); the held
// preamble (FirstChunkAt) only feeds dispatch_to_first_chunk_ms.
func TestActualTTFTUsesFirstContentNotPreamble(t *testing.T) {
	base := time.Now()
	pr := &registry.PendingRequest{
		RequestID: "req-content",
		Timing: &registry.RequestTiming{
			ReceivedAt:     base.Add(-50 * time.Millisecond),
			DispatchedAt:   base,
			FirstChunkAt:   base.Add(10 * time.Millisecond),  // held preamble
			FirstContentAt: base.Add(500 * time.Millisecond), // real content
		},
	}
	out := committedRouteOutcome(pr)
	if out.InvalidTTFT {
		t.Fatal("positive TTFT must not be flagged invalid")
	}
	if out.ActualTTFTMs != 500 {
		t.Fatalf("actual_ttft_ms must reflect FirstContentAt (500ms), got %f", out.ActualTTFTMs)
	}
	if out.DispatchToFirstChunkMs != 10 {
		t.Fatalf("dispatch_to_first_chunk_ms must reflect the preamble (10ms), got %f", out.DispatchToFirstChunkMs)
	}
}

// TestRetriedRequestTTFTClampedAndMetered reproduces the retried-request
// shared-Timing bug (the -378s rows): an early attempt's FirstContentAt minus a
// later attempt's overwritten DispatchedAt is hugely negative. It must clamp to 0
// and fire routing.invalid_ttft, never persist a negative.
func TestRetriedRequestTTFTClampedAndMetered(t *testing.T) {
	base := time.Now()
	pr := &registry.PendingRequest{
		RequestID: "req-retry-neg",
		Timing: &registry.RequestTiming{
			ReceivedAt:     base.Add(-time.Second),
			DispatchedAt:   base.Add(378 * time.Second), // later attempt overwrote dispatch far ahead
			FirstContentAt: base,                        // early attempt's content
		},
	}
	out := committedRouteOutcome(pr)
	if out.ActualTTFTMs != 0 {
		t.Fatalf("negative TTFT must clamp to 0, got %f", out.ActualTTFTMs)
	}
	if !out.InvalidTTFT {
		t.Fatal("negative TTFT must set InvalidTTFT for the loud guard")
	}

	srv := newTTFTTestServer(t)
	srv.updateInferenceRouteOutcomeWithModel("req-retry-neg", 0, "gpt-oss-20b", out)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.invalid_ttft", "reason=negative", "model=gpt-oss-20b") {
		t.Fatalf("routing.invalid_ttft{reason=negative,model=gpt-oss-20b} not emitted; counters=%v", counters)
	}
}
