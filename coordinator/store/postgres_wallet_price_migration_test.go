package store

import (
	"context"
	"testing"
)

func TestPostgresWalletPriceCleanupPreservesPlatform(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices"); err != nil {
		t.Fatalf("clean model_prices: %v", err)
	}
	if _, err := s.pool.Exec(ctx, "DELETE FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1'"); err != nil {
		t.Fatalf("clear migration marker: %v", err)
	}
	if err := s.CreateUser(&User{AccountID: "acct-real", PrivyUserID: "did:privy:real"}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	if err := s.SetModelPrice("acct-real", "gemma-4-26b", 65_000, 200_000); err != nil {
		t.Fatalf("set user price: %v", err)
	}
	if err := s.SetModelPrice("platform", "gpt-oss-20b", 50_000, 200_000); err != nil {
		t.Fatalf("set platform price: %v", err)
	}
	if err := s.SetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b", 1, 2); err != nil {
		t.Fatalf("set orphan wallet price: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if in, out, ok := s.GetModelPrice("platform", "gpt-oss-20b"); !ok || in != 50_000 || out != 200_000 {
		t.Errorf("platform price = (%d, %d, %v), want (50000, 200000, true)", in, out, ok)
	}
	if in, out, ok := s.GetModelPrice("acct-real", "gemma-4-26b"); !ok || in != 65_000 || out != 200_000 {
		t.Errorf("user price = (%d, %d, %v), want (65000, 200000, true)", in, out, ok)
	}
	if _, _, ok := s.GetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b"); ok {
		t.Error("orphan wallet-keyed price should be removed")
	}
	var marked bool
	if err := s.pool.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1')").Scan(&marked); err != nil {
		t.Fatalf("check marker: %v", err)
	}
	if !marked {
		t.Error("cleanup marker should be set after the cleanup runs")
	}
}

func TestPostgresWalletPriceCleanupRunsOnce(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices"); err != nil {
		t.Fatalf("clean model_prices: %v", err)
	}
	if _, err := s.pool.Exec(ctx,
		"INSERT INTO schema_migrations (id) VALUES ('cleanup_wallet_model_prices_v1') ON CONFLICT (id) DO NOTHING"); err != nil {
		t.Fatalf("set migration marker: %v", err)
	}
	if err := s.SetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b", 1, 2); err != nil {
		t.Fatalf("set orphan wallet price: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, _, ok := s.GetModelPrice("So1anaWa11etAddre55NotAUser", "gemma-4-26b"); !ok {
		t.Error("orphan row should survive when cleanup marker is already set")
	}
}
