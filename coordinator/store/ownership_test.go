package store

import (
	"context"
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
	_ = testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	second, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if second != nil {
		second.Close()
		t.Fatal("second coordinator acquired ownership")
	}
	if err == nil || !strings.Contains(err.Error(), "ownership is already held") {
		t.Fatalf("second coordinator error = %v", err)
	}
}
