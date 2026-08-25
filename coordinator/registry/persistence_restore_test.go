package registry

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLoadStoredProvidersDeterministicallyKeepsNewestIdentity(t *testing.T) {
	st := store.NewMemory(store.Config{})
	reg := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	reg.SetStore(st)
	now := time.Now()

	records := []store.ProviderRecord{
		{
			ID:           "session-old",
			SerialNumber: "SER-RESTORE",
			SEPublicKey:  "SE-RESTORE",
			RegisteredAt: now.Add(-2 * time.Hour),
			LastSeen:     now.Add(-time.Hour),
		},
		{
			ID:           "session-new",
			SerialNumber: "SER-RESTORE",
			SEPublicKey:  "SE-RESTORE",
			RegisteredAt: now.Add(-time.Minute),
			LastSeen:     now,
		},
	}
	for _, record := range records {
		if err := st.UpsertProvider(context.Background(), record); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", record.ID, err)
		}
	}

	for range 100 {
		lookup := reg.LoadStoredProviders()
		if got := lookup["SER-RESTORE"]; got == nil || got.ID != "session-new" {
			t.Fatalf("serial restore = %+v, want session-new", got)
		}
		if got := lookup["sekey:SE-RESTORE"]; got == nil || got.ID != "session-new" {
			t.Fatalf("SE-key restore = %+v, want session-new", got)
		}
	}
}

func TestKeepNewestStoredProviderUsesStableTieBreakers(t *testing.T) {
	now := time.Now()
	lookup := make(map[string]*store.ProviderRecord)
	olderRegistration := &store.ProviderRecord{
		ID:           "z-session",
		LastSeen:     now,
		RegisteredAt: now.Add(-time.Minute),
	}
	newerRegistration := &store.ProviderRecord{
		ID:           "a-session",
		LastSeen:     now,
		RegisteredAt: now,
	}
	lexicalWinner := &store.ProviderRecord{
		ID:           "b-session",
		LastSeen:     now,
		RegisteredAt: now,
	}

	keepNewestStoredProvider(lookup, "identity", olderRegistration)
	keepNewestStoredProvider(lookup, "identity", newerRegistration)
	keepNewestStoredProvider(lookup, "identity", lexicalWinner)

	if got := lookup["identity"]; got != lexicalWinner {
		t.Fatalf("tie-broken restore = %+v, want lexical winner %+v", got, lexicalWinner)
	}
}
