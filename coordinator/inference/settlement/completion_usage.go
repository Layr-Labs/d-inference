package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s Service) recordCompletionUsage(providerID string, pr *registry.PendingRequest, msg *protocol.InferenceCompleteMessage, totalCost int64, freeSelfRoute bool) {
	// Record in-memory usage (for current session queries).
	s.deps.Ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:            msg.RequestID,
		Model:            response.ConsumerModel(pr),
		PromptTokens:     msg.Usage.PromptTokens,
		CompletionTokens: msg.Usage.CompletionTokens,
		CostMicroUSD:     totalCost,
		Timestamp:        time.Now(),
	})

	// Persist usage to DB asynchronously — billing has already been
	// settled above, so this INSERT is not on the critical path. KeyID
	// carries per-key usage/spend attribution (empty for legacy callers).
	//
	// Skip the persistent (public-stats-feeding) row for FREE self-route:
	// it is private, owner-only traffic and must not appear in the public
	// /stats time-series, request-location, or flow aggregations. Private-only
	// providers only ever serve free self-route, so this also keeps their
	// traffic out of public stats. The owner still sees it via the in-memory
	// RecordUsage above (their session/transparency view).
	if !freeSelfRoute {
		saferun.Go(s.deps.Logger, "recordUsage", func() {
			s.deps.Store().RecordUsageFullWithPublicModel(providerID, pr.ConsumerKey, pr.KeyID, pr.Model, response.ConsumerModel(pr), msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost, pr.ConsumerLocation)
		})
	}

}
