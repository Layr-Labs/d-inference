// Package inventorytest shares backend-independent inventory assertions.
package inventorytest

import (
	"context"
	"testing"
	"time"

	storecache "github.com/eigeninference/d-inference/coordinator/store/cache"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

type InventorySessionSnapshot struct {
	Identity, Account string
	Closed            bool
	ClosedAt          *time.Time
	Observation       contracts.MachineObservation
}

func CheckMachineInventoryReconcile(t *testing.T, st contracts.Store, readInventorySession func(*testing.T, contracts.Store, string) InventorySessionSnapshot) {
	ctx := context.Background()
	inventory, _ := contracts.As[contracts.MachineInventoryStore](st)
	// Production discovers this capability through the cache decorator.
	reconciler, ok := contracts.As[contracts.MachineInventoryReconcileStore](storecache.New(st, storecache.DefaultCacheConfig()))
	if !ok {
		t.Fatal("reconciler unavailable through cached store")
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	old := now.Add(-10 * time.Minute)
	seed := func(id string, seen, heartbeat time.Time, provider bool) {
		t.Helper()
		if _, err := inventory.ObserveMachine(ctx, contracts.MachineObservation{SessionID: id, AccountID: "owner", SEKey: id, At: seen, OSMajor: 27}); err != nil {
			t.Fatal(err)
		}
		if provider {
			if err := st.OpenProviderSession(ctx, id, "", "owner"); err != nil {
				t.Fatal(err)
			}
			if err := st.TouchProviderSession(ctx, id, "", "owner", "", heartbeat); err != nil {
				t.Fatal(err)
			}
		}
	}
	seed("lost-close", old, old, true)
	closedAt := old.Add(2 * time.Minute)
	if err := st.CloseProviderSession(ctx, "lost-close", "disconnect", closedAt); err != nil {
		t.Fatal(err)
	}
	seed("restart", old, old.Add(time.Minute), true)
	seed("missing-provider-row", old, old, false)
	seed("fresh-provider", old, now, true)
	seed("fresh-inventory", now, old, true)
	original := readInventorySession(t, st, "restart")
	for i, want := range []int{2, 1, 0} {
		if n, err := reconciler.ReconcileMachineInventory(ctx, now.Add(-5*time.Minute), 2); err != nil || n != want {
			t.Fatalf("batch %d: count=%d err=%v", i, n, err)
		}
	}
	for _, id := range []string{"lost-close", "restart", "missing-provider-row"} {
		if r := readInventorySession(t, st, id); !r.Closed || !r.Observation.Disconnected || r.Account != "owner" {
			t.Fatalf("orphan not closed without losing attribution: %s %+v", id, r)
		}
	}
	if r := readInventorySession(t, st, "lost-close"); r.Observation.DisconnectReason != "provider_session" || r.ClosedAt != nil && !r.ClosedAt.Equal(closedAt) {
		t.Fatal("confirmed disconnect was not preserved")
	}
	for _, id := range []string{"fresh-provider", "fresh-inventory"} {
		if readInventorySession(t, st, id).Closed {
			t.Fatalf("live session closed: %s", id)
		}
	}
	// Only inferred closure may recover when fresh observations resume.
	live := contracts.MachineObservation{SessionID: "restart", AccountID: "owner", SEKey: "restart", At: now, OSMajor: 27}
	if _, err := inventory.ObserveMachine(ctx, live); err != nil {
		t.Fatal(err)
	}
	if r := readInventorySession(t, st, "restart"); r.Closed || r.Identity != original.Identity {
		t.Fatal("fresh observation did not recover the same identity")
	}
	late := live
	late.At = old
	late.Disconnected = true
	if _, err := inventory.ObserveMachine(ctx, late); err != nil {
		t.Fatal(err)
	}
	if readInventorySession(t, st, "restart").Closed {
		t.Fatal("late terminal capture overwrote newer liveness")
	}
	live.SessionID = "lost-close"
	live.SEKey = "lost-close"
	if _, err := inventory.ObserveMachine(ctx, live); err != nil {
		t.Fatal(err)
	}
	if !readInventorySession(t, st, "lost-close").Closed {
		t.Fatal("late capture reopened a confirmed disconnect")
	}
}
