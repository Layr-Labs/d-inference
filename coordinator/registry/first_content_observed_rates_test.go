package registry

import (
	"testing"
	"time"
)

func TestFirstContentObservedRatesAdmitFitAndRejectActualLateWork(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	pr := &PendingRequest{EstimatedPromptTokens: 4000, RequestedMaxTokens: 128,
		FirstContentDeadline: now.Add(4 * time.Second), MaxTTFTMs: 4000}
	c := measuredFirstContentCandidate(now)
	r.estimateFirstContent(c, pr, now)
	// 2s prefill + 330ms early decode + 1s delivery allowance fits 4s.
	// The removed blanket factor incorrectly made the identical work 5.66s.
	if c.firstContent.Status != FirstContentFeasible || c.firstContent.ConservativeMs != 3330 ||
		!firstContentCandidateAllowed(c, pr) || c.firstContent.PredictionSource != "" {
		t.Fatalf("observed-rate fit was rejected without a timing catalog: %+v", c.firstContent)
	}
	originalDeadline := pr.FirstContentDeadline
	pr.EstimatedPromptTokens = 10000
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != FirstContentPredictedLate || c.firstContent.ConservativeMs != 6330 || firstContentCandidateAllowed(c, pr) {
		t.Fatalf("genuinely late observed work was admitted: %+v", c.firstContent)
	}
	if pr.FirstContentDeadline != originalDeadline || pr.RequestedMaxTokens != 128 || pr.MaxTTFTMs != 4000 {
		t.Fatal("forecast changed deadline or physical output request")
	}
}

func TestFirstContentObservedRatesKeepUpperBoundsQueueAndTransport(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	for _, tc := range []struct {
		name   string
		adjust func(*routingCandidate, *PendingRequest)
		want   float64
	}{
		{"prompt upper bound", func(c *routingCandidate, pr *PendingRequest) { pr.FirstContentPromptTokens = 6000 }, 4330},
		{"queued prompt work", func(c *routingCandidate, pr *PendingRequest) {
			c.snapshot.firstContentPendingKnown = true
			c.snapshot.queuedPrefillTokens = 4000
		}, 5330},
		{"measured transport", func(c *routingCandidate, pr *PendingRequest) { c.snapshot.conservativeTransportMs = 1000 }, 4330},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr := &PendingRequest{EstimatedPromptTokens: 4000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(4 * time.Second), MaxTTFTMs: 4000}
			c := measuredFirstContentCandidate(now)
			tc.adjust(c, pr)
			r.estimateFirstContent(c, pr, now)
			if c.firstContent.ConservativeMs != tc.want || c.firstContent.Status != FirstContentPredictedLate || firstContentCandidateAllowed(c, pr) {
				t.Fatalf("work bound removed with rate haircut: %+v", c.firstContent)
			}
		})
	}
}
