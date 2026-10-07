package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

// AutopilotSamples projects immutable eligibility/envelope fields while queue
// membership is locked. Restricted/owner traffic does not create public placement
// pressure. No bodies, tool names, account identities or provider restrictions escape.
func (q *RequestQueue) AutopilotSamples(now time.Time, activeIDs map[string]bool) []autopilot.DemandSample {
	q.mu.Lock()
	defer q.mu.Unlock()
	var samples []autopilot.DemandSample
	for model, requests := range q.queues {
		for _, queued := range requests {
			p := queued.Pending
			if !publicAutopilotPending(p) || p.Model != model || activeIDs[queued.RequestID] ||
				now.Sub(queued.EnqueuedAt) >= q.maxWait {
				continue
			}
			select {
			case <-queued.DoneCh:
				continue
			default:
			}
			sample := autopilot.DemandSample{Model: model, ReceivedAt: queued.EnqueuedAt,
				PromptTokens: p.EstimatedPromptTokens, RequestedMaxTokens: p.RequestedMaxTokens,
				Requirements: p.Traits.AutopilotRequirements(p.RequiresVision), DeadlineKnown: true}
			if !p.FirstContentDeadline.IsZero() {
				if !p.FirstContentDeadline.After(now) {
					continue
				}
				sample.FirstContentDeadline = p.FirstContentDeadline.Sub(now)
			} else {
				if math.IsNaN(p.MaxTTFTMs) || math.IsInf(p.MaxTTFTMs, 0) || p.MaxTTFTMs < 0 || p.MaxTTFTMs > 1_800_000 {
					continue
				}
				// A legacy relative ceiling is immutable when no absolute clock
				// exists; RefreshFirstContentBudget leaves it untouched.
				sample.FirstContentDeadline = time.Duration(p.MaxTTFTMs * float64(time.Millisecond))
			}
			samples = append(samples, sample)
		}
	}
	return samples
}
