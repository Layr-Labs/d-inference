package postgres_test

import (
	"context"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func seedUser(t *testing.T, st store.Store, accountID string) *store.User {
	t.Helper()
	u := &store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Email: accountID + "@example.test"}
	if err := st.CreateUser(u); err != nil {
		t.Fatalf("CreateUser(%s): %v", accountID, err)
	}
	return u
}

func TestSmallModelsInterestPostgresDurability(t *testing.T) {
	st := testPostgresStore(t)
	ctx := context.Background()
	seedUser(t, st, "interest-durable")
	want := store.SmallModelsInterest{AccountID: "interest-durable", MacType: "Mac Mini", Chip: "M4", RAMGB: 24}
	if err := st.UpsertSmallModelsInterest(ctx, want); err != nil {
		t.Fatal(err)
	}
	if err := st.reopen(ctx); err != nil {
		t.Fatalf("repeat real migration: %v", err)
	}
	st.Close()
	reopened, err := openPostgresFixture(ctx, store.Config{DatabaseURL: os.Getenv("DATABASE_URL")})
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
