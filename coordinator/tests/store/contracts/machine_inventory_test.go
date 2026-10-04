package store_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func machineInventoryContract(t *testing.T, s store.MachineInventoryStore) {
	ctx := context.Background()
	now := time.Now().UTC()
	observe := func(session, account, se, serial string) store.MachineIdentity {
		t.Helper()
		id, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: session, AccountID: account, SEKey: se, VerifiedSerial: serial, At: now, OSMajor: 27, Source: "live_registration"})
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	a := observe("a", "owner", "se", "")
	if a.Assurance != "key_bound" {
		t.Fatal(a)
	}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: time.Now().String(), AccountID: "owner", SEKey: "se", At: now})
			if err != nil || id.ID != a.ID {
				t.Errorf("reconnect diverged: %+v %v", id, err)
			}
		}()
	}
	wg.Wait()
	b := observe("b", "owner", "new-se", "")
	if b.ID == a.ID {
		t.Fatal("unverified keys collapsed")
	}
	upgraded := observe("a", "owner", "se", "apple-verified-serial")
	if upgraded.ID != a.ID || upgraded.Assurance != "hardware_verified" {
		t.Fatal(upgraded)
	}
	merged := observe("b", "owner", "new-se", "apple-verified-serial")
	if merged.ID != a.ID {
		t.Fatal("verified rotation not merged")
	}
	if again := observe("c", "owner", "new-se", ""); again.ID != a.ID {
		t.Fatal("alias not moved")
	}
	if attacker := observe("d", "different-account", "se", ""); attacker.ID == a.ID {
		t.Fatal("cross-account alias accepted")
	}
	if _, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: "a", AccountID: "different-account", SEKey: "se", At: now}); err == nil {
		t.Fatal("session reassigned")
	}
	u := observe("u", "owner", "", "")
	v := observe("v", "owner", "", "")
	if u.ID == v.ID || u.Assurance != "provisional" {
		t.Fatal("provisional identities hidden")
	}
	if again := observe("u", "owner", "", ""); again.ID != u.ID {
		t.Fatal("provisional session changed")
	}
}

func TestMachineInventoryMemory(t *testing.T) {
	machineInventoryContract(t, memory.NewMemory(store.Config{}))
}
