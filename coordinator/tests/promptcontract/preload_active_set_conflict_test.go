package promptcontract_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

func TestPreloadActiveSetConflictRetiresWithoutFailureOrResidenceChange(t *testing.T) {
	input := activeSetInput(3, 2)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[:2]...)
	activeSetReconcile(t, policy, 0, input)
	old := activeSetLoadAll(t, policy, 0)
	input = activeSetInput(4, 2)
	activeSetReconcile(t, policy, time.Second, input)
	activeSetDemand(t, policy, time.Second, input.Verified[3])
	lease, ok := policy.BeginAttempt(time.Second)
	if !ok {
		t.Fatal("current changed-V operation did not begin")
	}
	before := policy.State()
	if policy.RetireConflict(time.Second, old) || policy.State().InflightOperation != lease.Operation {
		t.Fatal("old conflict retired a newer operation")
	}
	// That the key still needs its load shows in the fresh attempt admitted below.
	if !policy.RetireConflict(time.Second, lease) || policy.State().InflightOperation != 0 || len(policy.Successes()) != 0 {
		t.Fatal("current conflict did not retire without publication")
	}
	if after := policy.State(); !after.Key.Equal(before.Key) || !after.BatchRetryKey.Equal(before.BatchRetryKey) ||
		after.BatchRetryAt != before.BatchRetryAt || after.FailedResult {
		t.Fatal("unaccepted Rust operation changed demand/residence/retry/failure state")
	}
	fresh, ok := policy.BeginAttempt(time.Second)
	if !ok || fresh.Operation == lease.Operation || policy.RetireConflict(time.Second, lease) {
		t.Fatal("conflict imposed backoff or retired its replacement")
	}
	if !policy.CompleteAttempt(time.Second, fresh, fresh.Key.Desired, 0) {
		t.Fatal("independent current acknowledgement did not recover")
	}
	// Demand and residence show in the next replacement. The waiting fourth
	// contract takes the first's slot at exactly thirty seconds only if the
	// conflict left its wait, both admissions at zero and no failed member.
	activeSetReconcile(t, policy, 30*time.Second, input)
	if !slices.Equal(policy.Snapshot().Desired, activeSetContracts(2, 4)) {
		t.Fatal("unaccepted Rust operation changed demand/residence/retry/failure state")
	}
}

func TestPreloadActiveSetConflictCannotRehabilitateABAOrRetireForgedKey(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	lease, ok := policy.BeginAttempt(0)
	if !ok {
		t.Fatal("fixture did not acquire a lease")
	}
	forged := lease
	forged.Key.Verified = slices.Clone(lease.Key.Verified)
	forged.Key.Verified[0].ModelID = "other-model"
	if policy.RetireConflict(0, forged) || policy.State().InflightOperation == 0 {
		t.Fatal("forged exact key retired the real operation")
	}
	changed := input
	changed.Admissible = slices.Clone(input.Admissible[1:])
	activeSetReconcile(t, policy, time.Second, changed)
	current := activeSetReconcile(t, policy, 2*time.Second, input)
	if !current.Equal(lease.Key) {
		t.Fatal("fixture did not restore an irreversibly invalidated byte-equal K")
	}
	// The fence shows only when the lease's own callback arrives: under this
	// byte-equal key a lease that was never fenced would retire as accepted.
	if policy.RetireConflict(2*time.Second, lease) || policy.State().InflightOperation != 0 || len(policy.Successes()) != 0 {
		t.Fatal("ABA conflict reopened S or failed to retire its own callback")
	}
	fresh, ok := policy.BeginAttempt(2 * time.Second)
	if !ok || policy.RetireConflict(2*time.Second, lease) || policy.State().InflightOperation != fresh.Operation {
		t.Fatal("stale ABA callback retired the fresh lease")
	}
}
