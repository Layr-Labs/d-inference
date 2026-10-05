package store_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestSmallModelsInterestStoreContract(t *testing.T) {
	for _, backend := range []string{"memory", "postgres", "cached_memory", "cached_postgres"} {
		t.Run(backend, func(t *testing.T) {
			var st store.Store = memory.NewMemory(store.Config{})
			if backend == "postgres" || backend == "cached_postgres" {
				st = testPostgresStore(t)
			}
			if backend == "cached_memory" || backend == "cached_postgres" {
				st = store.NewCached(st, store.CacheConfig{})
			}
			ctx := context.Background()
			seedUser(t, st, "interest-a")
			seedUser(t, st, "interest-b")
			if _, err := st.GetSmallModelsInterest(ctx, "interest-a"); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("missing record: %v", err)
			}
			record := store.SmallModelsInterest{AccountID: "interest-a", MacType: "MacBook Pro", Chip: "M1", RAMGB: 16}
			if err := st.UpsertSmallModelsInterest(ctx, record); err != nil {
				t.Fatal(err)
			}
			first, err := st.GetSmallModelsInterest(ctx, "interest-a")
			if err != nil || first.RAMGB != 16 || first.CreatedAt.IsZero() || first.UpdatedAt.Before(first.CreatedAt) {
				t.Fatalf("persisted record: %+v %v", first, err)
			}
			record.Chip, record.RAMGB = "M4 Pro", 24
			if err := st.UpsertSmallModelsInterest(ctx, record); err != nil {
				t.Fatal(err)
			}
			updated, err := st.GetSmallModelsInterest(ctx, "interest-a")
			if err != nil || updated.RAMGB != 24 || !updated.CreatedAt.Equal(first.CreatedAt) || updated.UpdatedAt.Before(first.UpdatedAt) {
				t.Fatalf("upsert: %+v %v", updated, err)
			}
			updated.RAMGB = 999
			copy, err := st.GetSmallModelsInterest(ctx, "interest-a")
			if err != nil || copy.RAMGB != 24 {
				t.Fatalf("read copy mutated store: %+v %v", copy, err)
			}
			record.AccountID, record.RAMGB = "interest-b", 32
			if err := st.UpsertSmallModelsInterest(ctx, record); err != nil {
				t.Fatal(err)
			}
			var wg sync.WaitGroup
			failures := make(chan error, 12)
			for i := 0; i < 12; i++ {
				wg.Add(1)
				go func() { defer wg.Done(); failures <- st.UpsertSmallModelsInterest(ctx, record) }()
			}
			wg.Wait()
			close(failures)
			for err := range failures {
				if err != nil {
					t.Fatal(err)
				}
			}
			page, err := st.ListSmallModelsInterest(ctx, "", 1)
			if err != nil || len(page) != 1 || page[0].AccountID != "interest-a" || page[0].Email != "interest-a@example.test" {
				t.Fatalf("first page: %+v %v", page, err)
			}
			page, err = st.ListSmallModelsInterest(ctx, page[0].AccountID, 1)
			if err != nil || len(page) != 1 || page[0].AccountID != "interest-b" || page[0].RAMGB != 32 {
				t.Fatalf("second page: %+v %v", page, err)
			}
			page, err = st.ListSmallModelsInterest(ctx, page[0].AccountID, 1)
			if err != nil || len(page) != 0 {
				t.Fatalf("end page: %+v %v", page, err)
			}
			all, err := st.ListSmallModelsInterest(ctx, "", 100)
			if err != nil || len(all) != 2 {
				t.Fatalf("concurrent upserts duplicated accounts: %+v %v", all, err)
			}
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			if err := st.UpsertSmallModelsInterest(cancelled, record); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled write: %v", err)
			}
		})
	}
}

func TestSmallModelsInterestAutopilotComposition(t *testing.T) {
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			var inner store.Store = memory.NewMemory(store.Config{})
			if backend == "postgres" {
				inner = testPostgresStore(t)
			}
			st := store.NewCached(inner, store.CacheConfig{})
			ctx := context.Background()
			user := seedUser(t, st, "interest-autopilot")
			if _, err := st.GetUserByAccountID(user.AccountID); err != nil {
				t.Fatal(err)
			}
			ledger, ok := store.As[store.AutopilotStore](st)
			if !ok {
				t.Fatal("cached store hides Autopilot persistence")
			}
			event := store.AutopilotRecord{CommandID: uniqueID("interest"), ProviderID: "session", Phase: "proposed", At: time.Now().UTC(), Load: "candidate"}
			if err := ledger.RecordAutopilot(ctx, []store.AutopilotRecord{event}); err != nil {
				t.Fatal(err)
			}
			record := store.SmallModelsInterest{AccountID: user.AccountID, MacType: "Mac Mini", Chip: "M4", RAMGB: 24}
			if err := st.UpsertSmallModelsInterest(ctx, record); err != nil {
				t.Fatal(err)
			}
			record.RAMGB = 32
			if err := st.UpsertSmallModelsInterest(ctx, record); err != nil {
				t.Fatal(err)
			}
			event.Phase = "reserved"
			if err := ledger.RecordAutopilot(ctx, []store.AutopilotRecord{event}); err != nil {
				t.Fatal(err)
			}
			got, err := st.GetSmallModelsInterest(ctx, user.AccountID)
			if err != nil || got.RAMGB != 32 {
				t.Fatalf("Autopilot write changed interest: %+v %v", got, err)
			}
			rows, err := st.ListSmallModelsInterest(ctx, "", 100)
			if err != nil || len(rows) != 1 || rows[0].Email != user.Email {
				t.Fatalf("cached interest export: %+v %v", rows, err)
			}
			events, err := ledger.AutopilotRecords(ctx, event.At.Add(-time.Second), 1000)
			if err != nil {
				t.Fatal(err)
			}
			phases := map[string]bool{}
			for _, got := range events {
				if got.CommandID == event.CommandID {
					phases[got.Phase] = true
				}
			}
			if len(phases) != 2 || !phases["proposed"] || !phases["reserved"] {
				t.Fatalf("interest write changed Autopilot events: %+v", events)
			}
		})
	}
}
