package registry

import (
	"time"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = 256

	slotStatePenaltyRunning      = 0.0
	slotStatePenaltyUnknown      = 30_000.0
	slotStatePenaltyIdleShutdown = 20_000.0

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
	memoryPressurePenaltyMs  = 4_000.0
	cpuUsagePenaltyMs        = 1_500.0
	gpuUtilizationPenaltyMs  = 5_000.0
	thermalPenaltyFairMs     = 2_000.0
	thermalPenaltySeriousMs  = 8_000.0
	nearTieCostWindowMs      = 3_000.0
	challengeFreshnessMaxAge = 6 * time.Minute

	// kvCacheBytesPerToken is a per-token KV-cache size estimate used by
	// the free-memory admission gate.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit, prompt≈2330 + completion≈72):
	// 357,615 bytes/token (0.34 MB). Prior default of 0.5 MB was ~47%
	// too conservative — providers were being rejected for "no fit"
	// when they actually had room. Rounded up slightly to 400,000 to
	// leave headroom for larger models (70B class may be ~2x) without
	// re-running the gate per architecture. Refine per-model via
	// catalog metadata once more measurements exist.
	kvCacheBytesPerToken = 400_000 // ~0.38 MB; covers 7-8B with slack
	bytesPerGB           = 1 << 30

	// effectiveTPSLoadFactor controls how aggressively decode TPS
	// degrades as a provider takes on more concurrent requests. The
	// effective TPS used in cost is `decodeTPS / (1 + k * batchSize)`
	// where batchSize is the backend's currently-running request count.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit) at N=1/2/4/8 concurrent
	// decodes: per-request TPS = 92.8 / 69.5 / 35.9 / 29.6. Median
	// implied k = 0.27 (see scripts/calibrate-routing.sh load-factor).
	// Prior default 0.4 was ~48% too aggressive — it under-predicted
	// per-request TPS at small batch sizes, pushing traffic off the
	// big machines sooner than warranted.
	// Set to 0 to disable load scaling.
	effectiveTPSLoadFactor = 0.27
)
