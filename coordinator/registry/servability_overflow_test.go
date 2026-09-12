package registry

import (
	"math"
	"testing"
)

func TestServabilityRejectsOverflowingRequestSize(t *testing.T) {
	reg := New(testLogger())
	const model = "overflowing-request"
	makeTokenBudgetProvider(t, reg, "resident", model, 100, 0, 100_000, 80)
	for _, contextLimit := range []int{0, math.MaxInt} {
		verdict := reg.PredictServable(model, math.MaxInt, math.MaxInt, 1, contextLimit, RequestTraits{}, false)
		if verdict.Servable || verdict.RequestTokens != math.MaxInt {
			t.Errorf("overflowing request context=%d produced %+v", contextLimit, verdict)
		}
		want := ServabilityPromptTooLong
		if contextLimit > 0 {
			want = ServabilityContextExceeded
		}
		if verdict.Reason != want {
			t.Errorf("context=%d reason=%q, want %q", contextLimit, verdict.Reason, want)
		}
	}
	known := routingSnapshot{modelLoaded: true, activeTokenBudgetMax: math.MaxInt}
	if fits, reported := providerBudgetFits(&known, math.MaxInt, math.MaxInt); fits || !reported {
		t.Fatalf("overflowing request fit known budget: fits=%v known=%v", fits, reported)
	}
	unknown := routingSnapshot{modelLoaded: true}
	if fits, reported := providerBudgetFits(&unknown, math.MaxInt, math.MaxInt); !fits || reported {
		t.Fatalf("missing budget must retain fail-open semantics: fits=%v known=%v", fits, reported)
	}
}
