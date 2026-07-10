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
	first, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL, OwnershipEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL, OwnershipEnabled: true})
	if second != nil {
		second.Close()
		t.Fatal("second coordinator acquired ownership")
	}
	if err == nil || !strings.Contains(err.Error(), "ownership is already held") {
		t.Fatalf("second coordinator error = %v", err)
	}
}

func TestPostgresOwnershipConnectionLossFencesMutations(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	backend, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL, OwnershipEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
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
