package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"testing"
	"time"
)

func TestFirstContentObservedRatesAdmitFitAndRejectActualLateWork(t *testing.T) {
	now := time.Now()
	pr := forecast.Request{PromptTokens: 4000, UpperBoundTokens: 4000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128},
		Deadline: now.Add(4 * time.Second), MaxTTFTMS: 4000}
	c := measuredFirstContentEvidence(now)
	estimate := forecast.Evaluate(c, pr, now).Estimate
	// 2s prefill + 330ms early decode + 1s delivery allowance fits 4s.
	// The removed blanket factor incorrectly made the identical work 5.66s.
	if estimate.Status != forecast.Feasible || estimate.ConservativeMs != 3330 ||
		!forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) || estimate.PredictionSource != "" {
		t.Fatalf("observed-rate fit was rejected without a timing catalog: %+v", estimate)
	}
	originalDeadline := pr.Deadline
	pr.PromptTokens, pr.UpperBoundTokens = 10000, 10000
	estimate = forecast.Evaluate(c, pr, now).Estimate
	if estimate.Status != forecast.PredictedLate || estimate.ConservativeMs != 6330 || forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) {
		t.Fatalf("genuinely late observed work was admitted: %+v", estimate)
	}
	if pr.Deadline != originalDeadline || pr.Incoming.RequestedMaxTokens != 128 || pr.MaxTTFTMS != 4000 {
		t.Fatal("forecast changed deadline or physical output request")
	}
}

func TestFirstContentObservedRatesKeepUpperBoundsQueueAndTransport(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name   string
		adjust func(*forecast.Evidence, *forecast.Request)
		want   float64
	}{
		{"prompt upper bound", func(c *forecast.Evidence, pr *forecast.Request) { pr.UpperBoundTokens = 6000 }, 4330},
		{"queued prompt work", func(c *forecast.Evidence, pr *forecast.Request) { c.Workload.PrefillAhead = 4000 }, 5330},
		{"measured transport", func(c *forecast.Evidence, pr *forecast.Request) { c.Transport.ConservativeMS = 1000 }, 4330},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr := forecast.Request{PromptTokens: 4000, UpperBoundTokens: 4000, Incoming: performance.IncomingWork{RequestedMaxTokens: 128}, Deadline: now.Add(4 * time.Second), MaxTTFTMS: 4000}
			c := measuredFirstContentEvidence(now)
			tc.adjust(&c, &pr)
			estimate := forecast.Evaluate(c, pr, now).Estimate
			if estimate.ConservativeMs != tc.want || estimate.Status != forecast.PredictedLate || forecast.Allows(estimate, pr, c.Workload.WholeMacBusy) {
				t.Fatalf("work bound removed with rate haircut: %+v", estimate)
			}
		})
	}
}
