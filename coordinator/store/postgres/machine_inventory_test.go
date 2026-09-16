package postgres

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func machineInventoryContract(t *testing.T, s contracts.MachineInventoryStore) {
	ctx := context.Background()
	now := time.Now().UTC()
	observe := func(session, account, se, serial string) contracts.MachineIdentity {
		t.Helper()
		id, err := s.ObserveMachine(ctx, contracts.MachineObservation{SessionID: session, AccountID: account, SEKey: se, VerifiedSerial: serial, At: now, OSMajor: 27, Source: "live_registration"})
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
			id, err := s.ObserveMachine(ctx, contracts.MachineObservation{SessionID: time.Now().String(), AccountID: "owner", SEKey: "se", At: now})
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
	if _, err := s.ObserveMachine(ctx, contracts.MachineObservation{SessionID: "a", AccountID: "different-account", SEKey: "se", At: now}); err == nil {
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
	machineInventoryContract(t, memory.New(contracts.Config{}))
}

func TestMachineInventoryPostgres(t *testing.T) {
	s := testPostgresStore(t)
	machineInventoryContract(t, s)
	var count int
	if err := s.pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM darkbloom_machine_merges`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("merges: %d %v", count, err)
	}
	var original, current string
	if err := s.pool.QueryRow(context.Background(), `SELECT original_machine_id,machine_id FROM darkbloom_machine_sessions WHERE session_id='b'`).Scan(&original, &current); err != nil || original == current {
		t.Fatalf("lost original attribution: %v", err)
	}
}

func TestMachineBackfillCannotOverwriteLiveSessionPostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now()
	live := contracts.MachineObservation{SessionID: "live", AccountID: "real-owner", SEKey: "se", At: now, Source: "live_registration", OSMajor: 27}
	id, err := s.ObserveMachine(ctx, live)
	if err != nil {
		t.Fatal(err)
	}
	old := contracts.MachineObservation{SessionID: "live", AccountID: "old-owner", SEKey: "other", At: now.Add(-time.Hour), Source: "historical_registration", Disconnected: true}
	got, err := s.ObserveMachine(ctx, old)
	if err != nil || got.ID != id.ID {
		t.Fatalf("backfill overwrite: %+v %v", got, err)
	}
	var account string
	var disconnected *time.Time
	if err = s.pool.QueryRow(ctx, `SELECT account_id,disconnected_at FROM darkbloom_machine_sessions WHERE session_id='live'`).Scan(&account, &disconnected); err != nil || account != "real-owner" || disconnected != nil {
		t.Fatal("backfill changed live attribution")
	}
}
