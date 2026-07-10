package store

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
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
	select {
	case <-backend.OwnershipLost():
	case <-time.After(2 * time.Second):
		t.Fatal("ownership loss was not detected")
	}
	if err := backend.Credit("fenced-account", 1, LedgerStripeDeposit, "fenced"); !errors.Is(err, ErrOwnershipLost) {
		t.Fatalf("mutation after ownership loss error = %v", err)
	}
}
