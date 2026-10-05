package registry_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// This witness compiles on the original count-limited tracker. It measures
// logical retained hash bytes in both existing structures, not allocator/RSS
// usage: source plans and strings may share backing. No huge prompt/model is
// created, and ordinary inference must remain eligible when cache is declined.
func TestCacheAttemptTrackedHashBytesStayWithinLogicalBudget(t *testing.T) {
	const attempts, boundaries, ceiling = 137, 3906, uint64(64 << 20)
	r, provider, _ := newExactRoutingFixture(t)
	anchors := make([]protocol.PrefixCacheAnchor, boundaries)
	for i := range anchors {
		anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
	}
	plan := exactTestPlan(anchors...)
	plan.PromptTokenCount = 999937
	plan = boundTestCachePlan(r, plan)
	requests := make([]*production.PendingRequest, 0, attempts)
	t.Cleanup(func() {
		for _, request := range requests {
			r.ForgetCacheAttempt(request)
		}
		_, retained := r.CacheRoutingStateCounts()
		if retained != 0 {
			t.Errorf("owned attempt cleanup left %d records", retained)
		}
	})
	participating := 0
	for i := range attempts {
		request := &production.PendingRequest{RequestID: fmt.Sprintf("logical-budget-%d", i), Model: "model", CachePlan: plan}
		requests = append(requests, request)
		if err := r.PrepareCacheAttempt(request, provider); err != nil {
			t.Fatalf("optional cache refusal became an inference error: %v", err)
		}
		if request.CacheRoutingParticipates() {
			participating++
		}
	}
	// The retained receipt directory is the fixture's own dependency. Frozen
	// claims do not enumerate their hashes, so each plan boundary a record's
	// claims bind is counted once more for that second structure.
	var logicalHashes uint64
	for _, attempt := range r.config.Attempts.Entries() {
		for _, boundary := range attempt.Plan.Boundaries {
			logicalHashes += uint64(len(boundary.ChainHash))
			if attempt.ExpectedBoundaries.Matches(boundary) {
				logicalHashes += uint64(len(boundary.ChainHash))
			}
		}
	}
	retained := r.config.Attempts.Len()
	if participating == 0 || retained == 0 {
		t.Fatal("positive cache-admission control missing")
	}
	if retained == attempts || logicalHashes > ceiling {
		t.Errorf("count-only admission retained %d/%d records and %d logical hash bytes, ceiling %d", retained, attempts, logicalHashes, ceiling)
	}
}
