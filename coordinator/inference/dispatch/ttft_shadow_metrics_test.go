package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestEmitTTFTShadowMetrics asserts the shadow admission/spread counters are
// emitted with the right tags for a would_shed + would_redirect decision.
func TestEmitTTFTShadowMetrics(t *testing.T) {
	srv := newTestController(t)
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
	counters := srv.deps.Metrics().Snapshot().Counters
	if !counterMatches(counters, "routing.ttft_admission", "decision=would_shed", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.ttft_admission{would_shed}; counters=%v", counters)
	}
	if !counterMatches(counters, "routing.ttft_spread", "would_redirect_to_idle=true", "model=gpt-oss-20b") {
		t.Fatalf("missing routing.ttft_spread{redirect=true}; counters=%v", counters)
	}
}

// TestEmitTTFTShadowMetricsServeAndNoRedirect covers the negative tag values.
func TestEmitTTFTShadowMetricsServeAndNoRedirect(t *testing.T) {
	srv := newTestController(t)
	srv.emitTTFTShadowMetrics("gpt-oss-20b", registry.RoutingDecision{
		ShadowEvaluated: true,
		ShadowMode:      "shadow",
	})
	counters := srv.deps.Metrics().Snapshot().Counters
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
	srv := newTestController(t)
	srv.emitTTFTShadowMetrics("gpt-oss-20b", registry.RoutingDecision{ShadowEvaluated: false})
	if got := len(srv.deps.Metrics().Snapshot().Counters); got != 0 {
		t.Fatalf("no shadow metrics expected when not evaluated, got %d counters", got)
	}
}
