package registry

import (
	"testing"
	"time"
)

func TestPendingModelLoadSweepPreservesExactDeadline(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	actions := r.reservePendingModelLoads([]modelLoadAction{{providerID: "session", modelID: "model"}}, now)
	if len(actions) != 1 {
		t.Fatal("initial model load was not reserved")
	}
	expiry, ok := pendingLoadExpiry(r, "session", "model")
	if !ok {
		t.Fatal("model load has no expiry")
	}
	r.expirePendingModelLoads(expiry)
	if !hasPendingLoad(r, "session") || r.pendingModelLoadCount(expiry) != 1 {
		t.Fatal("sweep removed the command at equality")
	}
	actions = r.reservePendingModelLoads([]modelLoadAction{{providerID: "session", modelID: "other-model"}}, expiry)
	if len(actions) != 0 {
		t.Fatal("unswept command allowed a second model on the session")
	}
	r.expirePendingModelLoads(expiry.Add(time.Nanosecond))
	if hasPendingLoad(r, "session") || r.pendingModelLoadCount(expiry) != 0 {
		t.Fatal("sweep retained the command after its deadline")
	}
}
