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
