package notifications

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type captureEmailClient struct {
	emails []Email
}

func (c *captureEmailClient) Send(_ context.Context, email Email) error {
	c.emails = append(c.emails, email)
	return nil
}

func TestProviderNotifierSendsOfflineAlertOncePerCooldown(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory(store.Config{})
	if err := st.CreateUser(&store.User{
		AccountID:   "acct_1",
		PrivyUserID: "did:privy:test",
		Email:       "owner@example.com",
	}); err != nil {
		t.Fatal(err)
	}
	rec := testProviderRecord("provider-1", "acct_1")
	rec.LastSeen = time.Now().Add(-10 * time.Minute)
	if err := st.UpsertProvider(ctx, rec); err != nil {
		t.Fatal(err)
	}

	email := &captureEmailClient{}
	notifier := NewProviderNotifierWithEmail(
		registry.New(testLogger()),
		st,
		Config{
			Enabled:          true,
			From:             "Darkbloom <providers@darkbloom.dev>",
			HeartbeatTimeout: 90 * time.Second,
			AlertCooldown:    24 * time.Hour,
		},
		testLogger(),
		email,
	)

	notifier.Check(ctx)
	if len(email.emails) != 1 {
		t.Fatalf("expected 1 email, got %d", len(email.emails))
	}
	if email.emails[0].To != "owner@example.com" {
		t.Fatalf("unexpected recipient %q", email.emails[0].To)
	}
	if email.emails[0].From != "Darkbloom <providers@darkbloom.dev>" {
		t.Fatalf("unexpected sender %q", email.emails[0].From)
	}

	notifier.Check(ctx)
	if len(email.emails) != 1 {
		t.Fatalf("expected cooldown to suppress duplicate email, got %d", len(email.emails))
	}
}

func TestProviderNotifierSendsVersionAndMDMReasons(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory(store.Config{})
	if err := st.CreateUser(&store.User{
		AccountID:   "acct_2",
		PrivyUserID: "did:privy:test2",
		Email:       "owner2@example.com",
	}); err != nil {
		t.Fatal(err)
	}
	rec := testProviderRecord("provider-2", "acct_2")
	rec.Version = "0.5.0"
	rec.TrustLevel = string(registry.TrustSelfSigned)
	rec.LastSeen = time.Now()
	if err := st.UpsertProvider(ctx, rec); err != nil {
		t.Fatal(err)
	}

	email := &captureEmailClient{}
	reg := registry.New(testLogger())
	reg.MinTrustLevel = registry.TrustHardware
	notifier := NewProviderNotifierWithEmail(
		reg,
		st,
		Config{
			Enabled:            true,
			MinProviderVersion: "0.6.4",
			HeartbeatTimeout:   90 * time.Second,
			AlertCooldown:      24 * time.Hour,
		},
		testLogger(),
		email,
	)

	notifier.Check(ctx)
	if len(email.emails) != 1 {
		t.Fatalf("expected 1 email, got %d", len(email.emails))
	}
	if !contains(email.emails[0].Text, "Provider update required") {
		t.Fatalf("missing version reason in %q", email.emails[0].Text)
	}
	if !contains(email.emails[0].Text, "MDM enrollment or hardware verification required") {
		t.Fatalf("missing MDM reason in %q", email.emails[0].Text)
	}
}

func testProviderRecord(id, accountID string) store.ProviderRecord {
	hardware, _ := json.Marshal(map[string]any{"chip_name": "M3 Max"})
	models, _ := json.Marshal([]any{})
	return store.ProviderRecord{
		ID:              id,
		AccountID:       accountID,
		SerialNumber:    "C02TEST12345",
		Hardware:        hardware,
		Models:          models,
		TrustLevel:      string(registry.TrustHardware),
		RuntimeVerified: true,
		Version:         "0.6.4",
		RegisteredAt:    time.Now().Add(-time.Hour),
		LastSeen:        time.Now(),
	}
}

func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
