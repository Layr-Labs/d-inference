package service_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type registrationInventoryStore struct {
	*memory.MemoryStore
	failNext bool
	writes   []store.MachineObservation
}

func (s *registrationInventoryStore) ObserveMachine(ctx context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	if s.failNext {
		s.failNext = false
		return store.MachineIdentity{}, errors.New("injected first observation failure")
	}
	id, err := s.MemoryStore.ObserveMachine(ctx, o)
	if err == nil {
		s.writes = append(s.writes, o)
	}
	return id, err
}

func TestInventoryCaptureRetainsRegistrationTimeAfterFailure(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		st := &registrationInventoryStore{MemoryStore: memory.NewMemory(store.Config{}), failNext: true}
		r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
		old := r.Register("old", nil, &protocol.RegisterMessage{})
		registeredAt := time.Now().UTC()
		oldSession := inventory.NewSession(inventory.SessionDependencies{Store: st, Provider: old}, store.MachineObservation{
			SessionID: old.ID, AccountID: "old-owner", Source: "live_registration",
		})
		oldSession.Capture(false)
		if len(st.writes) != 0 || oldSession.Identity().ID != "" {
			t.Fatal("failed capture persisted an observation")
		}
		time.Sleep(time.Minute)
		newer := r.Register("newer", nil, &protocol.RegisterMessage{})
		newSession := inventory.NewSession(inventory.SessionDependencies{Store: st, Provider: newer}, store.MachineObservation{
			SessionID: newer.ID, AccountID: "new-owner", Source: "live_registration",
		})
		newSession.Capture(false)
		time.Sleep(time.Minute)
		oldSession.Capture(false)
		time.Sleep(time.Minute)
		oldSession.Capture(true)
		if len(st.writes) != 3 || oldSession.Identity().ID == "" || newSession.Identity().ID == "" {
			t.Fatalf("successful inventory captures missing: %+v", st.writes)
		}
		newWrite, retry, terminal := st.writes[0], st.writes[1], st.writes[2]
		if !retry.At.After(newWrite.At) || !retry.RegisteredAt.Before(newWrite.RegisteredAt) {
			t.Fatalf("delayed capture reversed registration order: old=%+v new=%+v", retry, newWrite)
		}
		for _, o := range []store.MachineObservation{retry, terminal} {
			if !o.RegisteredAt.Equal(registeredAt) || o.RegisteredAt.Location() != time.UTC {
				t.Fatalf("capture did not preserve UTC registration time: %+v", o)
			}
			raw, err := json.Marshal(o)
			if err != nil {
				t.Fatal(err)
			}
			var decoded store.MachineObservation
			if err := json.Unmarshal(raw, &decoded); err != nil || !decoded.RegisteredAt.Equal(registeredAt) {
				t.Fatalf("registration timestamp lost in JSON: %s, %v", raw, err)
			}
		}
		if !terminal.Disconnected || !terminal.At.After(retry.At) {
			t.Fatal("terminal capture did not advance observation time")
		}
	})
}

func TestInventoryCaptureOmitsUnknownRegistrationTime(t *testing.T) {
	st := &registrationInventoryStore{MemoryStore: memory.NewMemory(store.Config{})}
	p := &registry.Provider{ID: "undated"}
	session := inventory.NewSession(inventory.SessionDependencies{Store: st, Provider: p}, store.MachineObservation{
		SessionID: p.ID, RegisteredAt: time.Now(),
	})
	session.Capture(false)
	if len(st.writes) != 1 || !st.writes[0].RegisteredAt.IsZero() {
		t.Fatalf("capture invented registration time for missing origin: %+v", st.writes)
	}
	raw, err := json.Marshal(st.writes[0])
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	if _, present := fields["registered_at"]; present {
		t.Fatalf("unknown registration time must be omitted: %s", raw)
	}
}
