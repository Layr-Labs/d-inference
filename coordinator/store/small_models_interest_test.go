package store

import (
	"context"
	"errors"
	"os"
	"sync"
	"testing"
)

func TestSmallModelsInterestStoreContract(t *testing.T) {
	for _, backend := range []string{"memory", "postgres", "cached_memory"} {
		t.Run(backend, func(t *testing.T) {
			var st Store = NewMemory(Config{})
			if backend == "postgres" {
				st = testPostgresStore(t)
			} else if backend == "cached_memory" {
				st = NewCached(st, CacheConfig{})
			}
			ctx := context.Background()
			seedUser(t, st, "interest-a")
			seedUser(t, st, "interest-b")
			if _, err := st.GetSmallModelsInterest(ctx, "interest-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("missing record: %v", err)
			}
			record := SmallModelsInterest{AccountID: "interest-a", MacType: "MacBook Pro", Chip: "M1", RAMGB: 16}
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

func TestSmallModelsInterestPostgresDurability(t *testing.T) {
	st := testPostgresStore(t)
	ctx := context.Background()
	seedUser(t, st, "interest-durable")
	want := SmallModelsInterest{AccountID: "interest-durable", MacType: "Mac Mini", Chip: "M4", RAMGB: 24}
	if err := st.UpsertSmallModelsInterest(ctx, want); err != nil {
		t.Fatal(err)
	}
	if err := st.migrate(ctx); err != nil {
		t.Fatalf("repeat real migration: %v", err)
	}
	st.Close()
	reopened, err := NewPostgres(ctx, Config{DatabaseURL: os.Getenv("DATABASE_URL")})
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	got, err := reopened.GetSmallModelsInterest(ctx, want.AccountID)
	if err != nil || got.Chip != want.Chip || got.RAMGB != want.RAMGB {
		t.Fatalf("new store readback: %+v %v", got, err)
	}
	if _, err := reopened.pool.Exec(ctx, `UPDATE users SET email=$1 WHERE account_id=$2`, "current@example.test", want.AccountID); err != nil {
		t.Fatal(err)
	}
	rows, err := reopened.ListSmallModelsInterest(ctx, "", 100)
	if err != nil || len(rows) != 1 || rows[0].Email != "current@example.test" {
		t.Fatalf("current email join: %+v %v", rows, err)
	}
}
