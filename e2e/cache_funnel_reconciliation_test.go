package e2e

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// cacheCounterSnapshot is every cache counter source read at one moment: the
// status projection (reuse funnel, receipt lifecycle, activation gate, holder
// count) and the admin metrics registry, which holds the token sums the public
// status leaves out.
type cacheCounterSnapshot struct {
	status   inference.ExactCacheStatus
	counters map[string]int64
}

func readCacheCounters(suite *testbed.Suite) cacheCounterSnapshot {
	// The projection is read directly: the HTTP endpoint caches it for a second.
	return cacheCounterSnapshot{
		status:   suite.Coordinator.Server.ExactCacheStatusSnapshot(),
		counters: suite.Coordinator.Server.Metrics().Snapshot().Counters,
	}
}

// cacheReconciliation checks that the reuse funnel, the receipt lifecycle
// counters, the activation gate and the usage rows clients received tell one
// story about a stretch of traffic. Every quantity is a difference from the
// baseline: the funnel and the metrics registry outlive a routing
// reconfiguration, while the lifecycle counters restart with it.
type cacheReconciliation struct {
	suite *testbed.Suite
	base  cacheCounterSnapshot
}

// beginCacheReconciliation takes the baseline. Call it after cache routing is
// configured and before the first request of the traffic to reconcile.
func beginCacheReconciliation(suite *testbed.Suite) *cacheReconciliation {
	return &cacheReconciliation{suite: suite, base: readCacheCounters(suite)}
}

type cacheIdentity struct {
	id          string
	left, right string
	leftValue   int64
	rightValue  int64
	// relation is "=" or "<=" for an asserted identity and "~" for one that is
	// only reported because either side may legitimately lead.
	relation string
	note     string
}

func (i cacheIdentity) holds() bool {
	switch i.relation {
	case "=":
		return i.leftValue == i.rightValue
	case "<=":
		return i.leftValue <= i.rightValue
	default:
		return true
	}
}

// check settles the system, then asserts the identities that are exact for the
// traffic since the baseline and reports the two-sided ones. rows holds one
// usage row per request sent since the baseline, and every request must have
// been a text request for a catalog model that its client read to completion.
// On any failure it prints every identity as one table before failing the test.
func (c *cacheReconciliation) check(t *testing.T, rows []exactCacheResponse) {
	t.Helper()
	// A handler writes its response before its deferred funnel close runs.
	require.Eventually(t, func() bool {
		funnel := c.suite.Coordinator.Server.ExactCacheStatusSnapshot().Funnel
		return funnel.InFlight == 0 && funnel.Entered == funnel.Closed
	}, 30*time.Second, 50*time.Millisecond, "a funnel request never closed")
	lifecycleStill := c.awaitLifecycleStill()
	end := readCacheCounters(c.suite)

	identities := c.funnelIdentities(end, rows)
	lifecycle := c.lifecycleIdentities(end)
	if lifecycleStill && !allHold(lifecycle) {
		// The holder count and the lifecycle counters are separate reads, and a
		// ready receipt is accepted for minutes after its terminal. One landing
		// between the reads is not a defect; a mismatch that survives a second
		// reading is.
		end = readCacheCounters(c.suite)
		lifecycle = c.lifecycleIdentities(end)
	}
	if !lifecycleStill {
		// Receipts are accepted for two minutes past an attempt's terminal, so
		// a lifecycle that is still moving cannot be held to equality.
		t.Logf("cache reconciliation: lifecycle counters did not hold still; I9 and I17 are reported, not asserted")
		for i := range lifecycle {
			lifecycle[i].relation = "~"
		}
	}
	identities = append(identities, lifecycle...)
	identities = append(identities, c.reportedIdentities(end, rows)...)

	var failed []string
	for _, identity := range identities {
		if !identity.holds() {
			failed = append(failed, identity.id)
		}
	}
	table := cacheIdentityTable(identities)
	t.Logf("cache reconciliation over %d requests:\n%s%s", len(rows), table, c.reusedTokenShares(end, rows))
	if len(failed) != 0 {
		t.Fatalf("cache counters do not reconcile: %s failed\n%s", strings.Join(failed, ", "), table)
	}
}

func allHold(identities []cacheIdentity) bool {
	for _, identity := range identities {
		if !identity.holds() {
			return false
		}
	}
	return true
}

// awaitLifecycleStill reports whether the receipt lifecycle held still for a
// provider heartbeat plus a second. It never fails the test: a provider that
// reconnected mid-run may keep reporting, and that is not what is under test.
func (c *cacheReconciliation) awaitLifecycleStill() bool {
	const still = cacheTelemetryHeartbeat + time.Second
	deadline := time.Now().Add(time.Minute)
	previous := c.suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	unchangedSince := time.Now()
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		current := c.suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
		if !reflect.DeepEqual(current, previous) {
			previous, unchangedSince = current, time.Now()
		}
		if time.Since(unchangedSince) >= still {
			return true
		}
	}
	return false
}

func (c *cacheReconciliation) counterDelta(end cacheCounterSnapshot, selects func(key string) bool) int64 {
	var delta int64
	for key, value := range end.counters {
		if selects(key) {
			delta += value - c.base.counters[key]
		}
	}
	return delta
}

func counterNamed(name string, labels ...string) func(string) bool {
	return func(key string) bool {
		if !strings.HasPrefix(key, name+"{") {
			return false
		}
		for _, label := range labels {
			if !strings.Contains(key, label) {
				return false
			}
		}
		return true
	}
}

// counterForReasons selects a funnel counter under exactly the named terminal
// reasons; one reason's name may be the prefix of another's.
func counterForReasons(name string, reasons ...string) func(string) bool {
	return func(key string) bool {
		if !strings.HasPrefix(key, name+"{") {
			return false
		}
		for _, reason := range reasons {
			if strings.Contains(key, "reason="+reason+",") || strings.Contains(key, "reason="+reason+"}") {
				return true
			}
		}
		return false
	}
}

func difference(end, base uint64) int64 { return int64(end) - int64(base) }

// funnelIdentities are exact whenever the funnel is quiescent and every row's
// request was completed by its client.
func (c *cacheReconciliation) funnelIdentities(end cacheCounterSnapshot, rows []exactCacheResponse) []cacheIdentity {
	funnel, base := end.status.Funnel, c.base.status.Funnel
	var overReasons, hitRequests uint64
	for i, reason := range funnel.Reasons {
		overReasons += reason.Requests
		if reason.Reason == "hit" || reason.Reason == "hit_without_selection" {
			hitRequests += reason.Requests - base.Reasons[i].Requests
		}
	}
	var rowsWithReuse, rowCachedTokens int64
	for _, row := range rows {
		rowCachedTokens += int64(row.cachedTokens)
		if row.cachedTokens > 0 {
			rowsWithReuse++
		}
	}
	reused := c.counterDelta(end, counterNamed("exact_cache_funnel_reused_tokens_total"))
	reusedOnHits := c.counterDelta(end, counterForReasons("exact_cache_funnel_reused_tokens_total", "hit", "hit_without_selection"))
	identities := []cacheIdentity{
		{id: "I1a", left: "funnel.entered", leftValue: int64(funnel.Entered), relation: "=",
			right: "funnel.closed+in_flight", rightValue: int64(funnel.Closed + funnel.InFlight)},
		{id: "I1b", left: "funnel.closed", leftValue: int64(funnel.Closed), relation: "=",
			right: "sum(reasons.requests)", rightValue: int64(overReasons)},
		{id: "I1c", left: "funnel.closed", leftValue: int64(funnel.Closed), relation: "=",
			right: "funnel.total.requests", rightValue: int64(funnel.Total.Requests)},
		{id: "I3", left: "rows.cached_tokens>0", leftValue: rowsWithReuse, relation: "=",
			right: "funnel.hit+hit_without_selection", rightValue: int64(hitRequests)},
		{id: "I3t", left: "funnel.hit+hit_without_selection", leftValue: int64(hitRequests), relation: "=",
			right: "funnel.memory+ssd hit requests", rightValue: difference(funnel.Total.MemoryHitRequests+funnel.Total.SSDHitRequests, base.Total.MemoryHitRequests+base.Total.SSDHitRequests)},
		{id: "I4a", left: "sum(rows.cached_tokens)", leftValue: rowCachedTokens, relation: "=",
			right: "funnel.reused_tokens", rightValue: reused},
		{id: "I4b", left: "funnel.reused_tokens", leftValue: reused, relation: "=",
			right: "funnel.reused_tokens on hits", rightValue: reusedOnHits},
	}
	gate, gateBase := end.status.Activation, c.base.status.Activation
	evaluated, sampledIn := difference(gate.Evaluated, gateBase.Evaluated), difference(gate.SampledIn, gateBase.SampledIn)
	admitted, planned := difference(gate.Admitted, gateBase.Admitted), difference(gate.Planned, gateBase.Planned)
	outcomes := planned + difference(gate.ColdOnly, gateBase.ColdOnly) + difference(gate.PlanEmpty, gateBase.PlanEmpty) +
		difference(gate.PlanFailed, gateBase.PlanFailed)
	return append(identities,
		cacheIdentity{id: "I14a", left: "activation.evaluated", leftValue: evaluated, relation: "=",
			right: "sampled_in+sampled_out", rightValue: sampledIn + difference(gate.SampledOut, gateBase.SampledOut)},
		cacheIdentity{id: "I14b", left: "activation.sampled_in", leftValue: sampledIn, relation: "=",
			right: "rate_limited+admitted", rightValue: difference(gate.RateLimited, gateBase.RateLimited) + admitted},
		cacheIdentity{id: "I14c", left: "activation.first_sight", leftValue: difference(gate.FirstSight, gateBase.FirstSight), relation: "<=",
			right: "activation.planned", rightValue: planned},
		cacheIdentity{id: "I14d", left: "planned+cold_only+plan_empty+plan_failed", leftValue: outcomes, relation: "<=",
			right: "activation.admitted", rightValue: admitted, note: "plan calls, not requests"})
}

// lifecycleIdentities are exact only once the receipt lifecycle is still.
func (c *cacheReconciliation) lifecycleIdentities(end cacheCounterSnapshot) []cacheIdentity {
	lifecycle, base := end.status.Lifecycle, c.base.status.Lifecycle
	skips := c.counterDelta(end, counterNamed("exact_cache_ssd_lookup_total", "outcome=skipped_", "protocol=v2"))
	var removed int64
	for reason, count := range lifecycle.HolderRemoved {
		removed += difference(count, base.HolderRemoved[reason])
	}
	return []cacheIdentity{
		{id: "I9", left: "lifecycle.ssd_lookups", leftValue: difference(lifecycle.SSDLookups, base.SSDLookups), relation: "=",
			right:      "ssd_hits+ssd_misses+skip receipts",
			rightValue: difference(lifecycle.SSDHits, base.SSDHits) + difference(lifecycle.SSDMisses, base.SSDMisses) + skips,
			note:       "accepted SSD receipts, per attempt"},
		{id: "I17", left: "holder_added-holder_removed", leftValue: difference(lifecycle.HolderAdded, base.HolderAdded) - removed, relation: "=",
			right: "holders", rightValue: int64(end.status.Holders - c.base.status.Holders)},
	}
}

// reportedIdentities compare a per-request count with a per-attempt one, or
// two token sources. Either side can lead for a legitimate reason (a retry, a
// rejected or dropped receipt, a tokenizer difference), so they are printed
// for a reader to judge and never fail the test.
func (c *cacheReconciliation) reportedIdentities(end cacheCounterSnapshot, rows []exactCacheResponse) []cacheIdentity {
	funnel, base := end.status.Funnel, c.base.status.Funnel
	lifecycle, lifecycleBase := end.status.Lifecycle, c.base.status.Lifecycle
	ssdHitReceipts := difference(lifecycle.SSDHits, lifecycleBase.SSDHits)
	var rowPromptTokens int64
	for _, row := range rows {
		rowPromptTokens += int64(row.promptTokens)
	}
	explained := fmt.Sprintf("retries=%d late_completions=%d lookup_rejected=%d",
		difference(funnel.Total.Attempts, base.Total.Attempts)-difference(funnel.Total.Dispatched, base.Total.Dispatched),
		difference(funnel.Late.Completions, base.Late.Completions),
		c.counterDelta(end, counterNamed("exact_cache_receipt_total", "outcome=rejected", "type=lookup_v2")))
	ssdHitCompletions := c.counterDelta(end, counterNamed("exact_cache_usage_total", "outcome=hit", "tier=ssd"))
	return []cacheIdentity{
		{id: "I2", left: "funnel.entered", leftValue: difference(funnel.Entered, base.Entered), relation: "~",
			right: "requests sent", rightValue: int64(len(rows)), note: "the only check that notices a request that never entered"},
		{id: "I5", left: "billed cached tokens, all tiers", relation: "~", right: "funnel reused + late reused",
			leftValue: c.counterDelta(end, counterNamed("exact_cache_cached_tokens_total")),
			rightValue: c.counterDelta(end, counterNamed("exact_cache_funnel_reused_tokens_total")) +
				c.counterDelta(end, counterNamed("exact_cache_funnel_late_reused_tokens_total")),
			note: "equal when every request was in the funnel population"},
		{id: "I8c", left: "usage{hit,ssd} completions", leftValue: ssdHitCompletions, relation: "~",
			right:      "funnel ssd hit requests + late ssd hits",
			rightValue: difference(funnel.Total.SSDHitRequests+funnel.Late.SSDHitCompletions, base.Total.SSDHitRequests+base.Late.SSDHitCompletions),
			note:       "equal when every request was in the funnel population"},
		{id: "I8", left: "usage{hit,ssd} completions", relation: "~", right: "lifecycle.ssd_hits", rightValue: ssdHitReceipts, note: explained,
			leftValue: ssdHitCompletions},
		{id: "I8f", left: "funnel.ssd_hit_requests", relation: "~", right: "lifecycle.ssd_hits", rightValue: ssdHitReceipts, note: explained,
			leftValue: difference(funnel.Total.SSDHitRequests, base.Total.SSDHitRequests)},
		{id: "I11", left: "accepted lookup receipts", relation: "~", right: "funnel.lookup_outcome_reported", note: explained,
			leftValue:  c.counterDelta(end, counterNamed("exact_cache_receipt_total", "outcome=accepted", "type=lookup_v2")),
			rightValue: difference(funnel.Total.LookupOutcomeReported, base.Total.LookupOutcomeReported)},
		{id: "I18", left: "funnel planner prompt tokens", relation: "~", right: "funnel provider prompt tokens",
			leftValue:  c.counterDelta(end, counterNamed("exact_cache_funnel_prompt_tokens_total")),
			rightValue: c.counterDelta(end, counterNamed("exact_cache_funnel_provider_prompt_tokens_total")),
			note:       "planner counts every planned request, provider every completed one"},
		{id: "I18r", left: "sum(rows.prompt_tokens)", leftValue: rowPromptTokens, relation: "~", right: "funnel provider prompt tokens",
			rightValue: c.counterDelta(end, counterNamed("exact_cache_funnel_provider_prompt_tokens_total"))},
	}
}

// reusedTokenShares prints each share with its numerator and denominator, so
// no ratio is quoted without the population it describes.
func (c *cacheReconciliation) reusedTokenShares(end cacheCounterSnapshot, rows []exactCacheResponse) string {
	var rowCached, rowPrompt int64
	for _, row := range rows {
		rowCached, rowPrompt = rowCached+int64(row.cachedTokens), rowPrompt+int64(row.promptTokens)
	}
	share := func(label string, numerator, denominator int64) string {
		if denominator == 0 {
			return fmt.Sprintf("  %-44s %d / 0\n", label, numerator)
		}
		return fmt.Sprintf("  %-44s %d / %d = %.4f\n", label, numerator, denominator, float64(numerator)/float64(denominator))
	}
	const reused, providerPrompt = "exact_cache_funnel_reused_tokens_total", "exact_cache_funnel_provider_prompt_tokens_total"
	prompt := c.counterDelta(end, counterNamed(providerPrompt))
	saved := c.counterDelta(end, counterNamed("exact_cache_funnel_prefill_saved_tokens_total"))
	return "reused-token share (numerator / denominator):\n" +
		share("client rows (customer bill): cached / prompt", rowCached, rowPrompt) +
		share("funnel, provider-reported: reused / prompt", c.counterDelta(end, counterNamed(reused)), prompt) +
		share("funnel, depth on hits: reused / prompt", c.counterDelta(end, counterForReasons(reused, "hit", "hit_without_selection")),
			c.counterDelta(end, counterForReasons(providerPrompt, "hit", "hit_without_selection"))) +
		share("funnel, work skipped: prefill saved / prompt", saved, prompt) +
		share("funnel, prediction kept: reused / predicted", c.counterDelta(end, counterForReasons(reused, "hit")),
			c.counterDelta(end, counterForReasons("exact_cache_funnel_predicted_tokens_total", "hit"))) +
		fmt.Sprintf("  %-44s %d\n", "funnel, recomputed tokens: prompt - saved", prompt-saved)
}

func cacheIdentityTable(identities []cacheIdentity) string {
	var table strings.Builder
	fmt.Fprintf(&table, "  %-5s %-42s %8s %-2s %-36s %8s %6s  %s\n", "id", "left", "", "", "right", "", "delta", "")
	for _, identity := range identities {
		verdict := "ok"
		switch {
		case identity.relation == "~":
			verdict = "reported"
		case !identity.holds():
			verdict = "FAIL"
		}
		fmt.Fprintf(&table, "  %-5s %-42s %8d %-2s %-36s %8d %6d  %s %s\n", identity.id, identity.left, identity.leftValue,
			identity.relation, identity.right, identity.rightValue, identity.leftValue-identity.rightValue, verdict, identity.note)
	}
	return table.String()
}
