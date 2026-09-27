package promptcontract

import (
	"maps"
	"reflect"
	"slices"
	"testing"
	"time"
)

func TestPreloadActiveSetConflictRetiresWithoutFailureOrResidenceChange(t *testing.T) {
	input := activeSetInput(3, 2)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[:2]...)
	activeSetReconcile(t, policy, 0, input)
	old := activeSetLoadAll(t, policy, 0)
	input = activeSetInput(4, 2)
	activeSetReconcile(t, policy, time.Second, input)
	activeSetDemand(t, policy, time.Second, input.Verified[3])
	lease, ok := policy.beginAttempt(time.Second)
	if !ok {
		t.Fatal("current changed-V operation did not begin")
	}
	demand, members, retry := maps.Clone(policy.demand), maps.Clone(policy.members), maps.Clone(policy.retryAt)
	key, retryKey, retryAt := policy.snapshot(), policy.batchRetryKey, policy.batchRetryAt
	if policy.retireConflict(time.Second, old) || policy.inflight == nil || policy.inflight.operation != lease.operation {
		t.Fatal("old conflict retired a newer operation")
	}
	if !policy.retireConflict(time.Second, lease) || policy.inflight != nil || !policy.needsLoad || len(policy.successes()) != 0 {
		t.Fatal("current conflict did not retire without publication")
	}
	if !reflect.DeepEqual(policy.demand, demand) || !reflect.DeepEqual(policy.members, members) ||
		!reflect.DeepEqual(policy.retryAt, retry) || !policy.snapshot().equal(key) ||
		!policy.batchRetryKey.equal(retryKey) || policy.batchRetryAt != retryAt || policy.failedResult {
		t.Fatal("unaccepted Rust operation changed demand/residence/retry/failure state")
	}
	fresh, ok := policy.beginAttempt(time.Second)
	if !ok || fresh.operation == lease.operation || policy.retireConflict(time.Second, lease) {
		t.Fatal("conflict imposed backoff or retired its replacement")
	}
	if !policy.completeAttempt(time.Second, fresh, fresh.key.Desired, 0) {
		t.Fatal("independent current acknowledgement did not recover")
	}
}

func TestPreloadActiveSetConflictCannotRehabilitateABAOrRetireForgedKey(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	lease, ok := policy.beginAttempt(0)
	if !ok {
		t.Fatal("fixture did not acquire a lease")
	}
	forged := lease
	forged.key.Verified = slices.Clone(lease.key.Verified)
	forged.key.Verified[0].ModelID = "other-model"
	if policy.retireConflict(0, forged) || policy.inflight == nil {
		t.Fatal("forged exact key retired the real operation")
	}
	changed := input
	changed.Admissible = slices.Clone(input.Admissible[1:])
	activeSetReconcile(t, policy, time.Second, changed)
	current := activeSetReconcile(t, policy, 2*time.Second, input)
	if !current.equal(lease.key) || !policy.inflightInvalidated {
		t.Fatal("fixture did not restore an irreversibly invalidated byte-equal K")
	}
	if policy.retireConflict(2*time.Second, lease) || policy.inflight != nil || len(policy.successes()) != 0 {
		t.Fatal("ABA conflict reopened S or failed to retire its own callback")
	}
	fresh, ok := policy.beginAttempt(2 * time.Second)
	if !ok || policy.retireConflict(2*time.Second, lease) || policy.inflight == nil || policy.inflight.operation != fresh.operation {
		t.Fatal("stale ABA callback retired the fresh lease")
	}
}
