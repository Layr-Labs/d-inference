package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/admission"
	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = admission.DefaultRequestedMaxTokens

	// Penalty constants. Phase 3 raised queueDepthPenaltyMs (1000→3000),
	// totalPendingPenaltyMs (250→750), and nearTieCostWindowMs (750→2500).
	// The old values let a fast provider with 1-2 in-flight requests
	// outscore an idle slow provider, because the per-request decode-cost
	// gap (~3-10 s) dwarfed the queue penalty (~1 s/request). The new
	// values make one queued request roughly equivalent to one
	// slow-provider decode, so the cost function actually spreads load
	// across the fleet. Wider tie window admits more candidates to the
	// queue-depth tie-break + random distribution.
	queueDepthPenaltyMs      = 3_000.0
	totalPendingPenaltyMs    = 750.0
	nearTieCostWindowMs      = 3_000.0
	challengeFreshnessMaxAge = 16 * time.Minute

	kvCacheBytesPerToken = admission.DefaultKVBytesPerToken
	bytesPerGB           = admission.BytesPerGiB

	// One measured coefficient shared by admission and warm-pool planning.
	effectiveTPSLoadFactor = throughput.LoadFactor
)
