package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPostgresCoordinatorOwnershipIsSingleActive(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	reset, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reset.Exec(ctx,
		`DELETE FROM public.schema_migrations
		 WHERE id = 'coordinator_ownership_activated'`,
	); err != nil {
		reset.Close(ctx)
		t.Fatal(err)
	}
	reset.Close(ctx)
	legacy, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	if err := legacy.ActivateCoordinatorOwnership(ctx, false); err != nil {
		t.Fatal(err)
	}
	activating, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	if err := activating.ActivateCoordinatorOwnership(ctx, true); err == nil ||
		!strings.Contains(err.Error(), "ownership is already held") {
		t.Fatalf("enabled contender against legacy owner error = %v", err)
	}
	activating.Close()
	legacy.Close()

	first, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if err := first.ActivateCoordinatorOwnership(ctx, true); err != nil {
		t.Fatal(err)
	}
	second, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	err = second.ActivateCoordinatorOwnership(ctx, true)
	if err == nil {
		t.Fatal("second coordinator acquired ownership")
	}
	if err == nil || !strings.Contains(err.Error(), "ownership is already held") {
		t.Fatalf("second coordinator error = %v", err)
	}
	first.Close()
	disabled, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer disabled.Close()
	err = disabled.ActivateCoordinatorOwnership(ctx, false)
	if err == nil || !strings.Contains(err.Error(), "cannot be disabled") {
		t.Fatalf("ownership disable error = %v", err)
	}
}

func TestPostgresOwnershipConnectionLossFencesMutations(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := ApplyPostgresMigrations(ctx, databaseURL, MigrationOptions{}); err != nil {
		t.Fatal(err)
	}
	backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if err := backend.ActivateCoordinatorOwnership(ctx, true); err != nil {
		t.Fatal(err)
	}
	if err := backend.ownershipConn.Conn().Close(ctx); err != nil {
		t.Fatal(err)
	}
	mutationCtx, mutationCancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	_, mutationErr := backend.pool.Exec(
		mutationCtx,
		`INSERT INTO provider_tokens (token_hash, provider_id, created_at)
		 VALUES ('stale-owner-token', 'stale-owner', NOW())`,
	)
	mutationCancel()
	if mutationErr == nil {
		t.Fatal("direct pool mutation succeeded after ownership lock loss")
	}
	select {
	case <-backend.OwnershipLost():
	case <-time.After(2 * time.Second):
		t.Fatal("ownership loss was not detected")
	}
	if err := backend.Credit("fenced-account", 1, LedgerStripeDeposit, "fenced"); !errors.Is(err, ErrOwnershipLost) {
		t.Fatalf("mutation after ownership loss error = %v", err)
	}
}
