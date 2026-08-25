package store

import (
	"context"
	"testing"
	"time"
)

func TestProviderWaitlistUpsertByNormalizedEmail(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			firstSubmission := time.Date(2026, 8, 25, 12, 0, 0, 0, time.UTC)
			if err := backend.UpsertProviderWaitlistSignup(ctx, ProviderWaitlistSignup{
				Email:       " Owner@Example.COM ",
				Chip:        "M2",
				MemoryGB:    24,
				SubmittedAt: firstSubmission,
			}); err != nil {
				t.Fatalf("first upsert: %v", err)
			}

			secondSubmission := firstSubmission.Add(time.Hour)
			if err := backend.UpsertProviderWaitlistSignup(ctx, ProviderWaitlistSignup{
				Email:        "owner@example.com",
				Chip:         "other",
				MemoryGB:     64,
				GPUCores:     40,
				OtherMachine: "M6 developer kit",
				SubmittedAt:  secondSubmission,
			}); err != nil {
				t.Fatalf("second upsert: %v", err)
			}

			signups, err := backend.ListProviderWaitlistSignups(ctx, 10)
			if err != nil {
				t.Fatalf("list signups: %v", err)
			}
			if len(signups) != 1 {
				t.Fatalf("signup count = %d, want 1", len(signups))
			}
			got := signups[0]
			if got.Email != "owner@example.com" {
				t.Fatalf("email = %q, want normalized email", got.Email)
			}
			if got.Chip != "other" || got.MemoryGB != 64 ||
				got.GPUCores != 40 || got.OtherMachine != "M6 developer kit" {
				t.Fatalf("updated hardware = %#v", got)
			}
			if !got.SubmittedAt.Equal(secondSubmission) {
				t.Fatalf("submitted_at = %s, want %s", got.SubmittedAt, secondSubmission)
			}
			if got.CreatedAt.IsZero() || got.UpdatedAt.IsZero() {
				t.Fatalf("timestamps not populated: %#v", got)
			}
		})
	}
}

func TestProviderWaitlistListLimit(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			for _, email := range []string{"one@example.com", "two@example.com"} {
				if err := backend.UpsertProviderWaitlistSignup(ctx, ProviderWaitlistSignup{
					Email:       email,
					Chip:        "M3 Max",
					MemoryGB:    64,
					SubmittedAt: time.Now().UTC(),
				}); err != nil {
					t.Fatalf("upsert %s: %v", email, err)
				}
			}

			signups, err := backend.ListProviderWaitlistSignups(ctx, 1)
			if err != nil {
				t.Fatalf("list signups: %v", err)
			}
			if len(signups) != 1 {
				t.Fatalf("signup count = %d, want 1", len(signups))
			}
		})
	}
}

func TestProviderWaitlistRejectsInvalidHardwareAcrossStores(t *testing.T) {
	tests := []struct {
		name   string
		signup ProviderWaitlistSignup
	}{
		{
			name: "memory below range",
			signup: ProviderWaitlistSignup{
				Email: "owner@example.com", Chip: "M4", MemoryGB: 3,
			},
		},
		{
			name: "memory above range",
			signup: ProviderWaitlistSignup{
				Email: "owner@example.com", Chip: "M4", MemoryGB: 1025,
			},
		},
		{
			name: "negative GPU cores",
			signup: ProviderWaitlistSignup{
				Email: "owner@example.com", Chip: "M4", MemoryGB: 32, GPUCores: -1,
			},
		},
		{
			name: "GPU cores above range",
			signup: ProviderWaitlistSignup{
				Email: "owner@example.com", Chip: "M4", MemoryGB: 32, GPUCores: 513,
			},
		},
	}

	for backendName, backend := range storeBackends(t) {
		for _, test := range tests {
			t.Run(backendName+"/"+test.name, func(t *testing.T) {
				if err := backend.UpsertProviderWaitlistSignup(
					context.Background(), test.signup); err == nil {
					t.Fatal("invalid waitlist hardware was accepted")
				}
			})
		}
	}
}

func TestProviderWaitlistMigratesLegacyConsentColumn(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	legacy := newWithdrawableMigrationStore(t, databaseURL)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := legacy.pool.Exec(ctx, `
		CREATE TABLE provider_waitlist_signups (
			email TEXT PRIMARY KEY,
			chip TEXT NOT NULL,
			memory_gb INT NOT NULL,
			other_machine TEXT NOT NULL DEFAULT '',
			consented_at TIMESTAMPTZ NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
		INSERT INTO provider_waitlist_signups (
			email, chip, memory_gb, consented_at
		) VALUES ('legacy@example.com', 'M3 Max', 64, '2026-08-01T12:00:00Z')
	`); err != nil {
		t.Fatal(err)
	}

	migrated, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer migrated.Close()
	signups, err := migrated.ListProviderWaitlistSignups(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(signups) != 1 ||
		signups[0].Email != "legacy@example.com" ||
		signups[0].GPUCores != 0 ||
		signups[0].SubmittedAt.IsZero() {
		t.Fatalf("migrated signup = %+v", signups)
	}

	var oldExists, newExists bool
	if err := migrated.pool.QueryRow(ctx, `
		SELECT
			EXISTS (
				SELECT 1 FROM information_schema.columns
				WHERE table_schema = current_schema()
				  AND table_name = 'provider_waitlist_signups'
				  AND column_name = 'consented_at'
			),
			EXISTS (
				SELECT 1 FROM information_schema.columns
				WHERE table_schema = current_schema()
				  AND table_name = 'provider_waitlist_signups'
				  AND column_name = 'submitted_at'
			)
	`).Scan(&oldExists, &newExists); err != nil {
		t.Fatal(err)
	}
	if oldExists || !newExists {
		t.Fatalf("legacy/new columns = %v/%v", oldExists, newExists)
	}
}
