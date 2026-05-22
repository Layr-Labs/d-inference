package liveness

import (
	"context"
	"testing"
	"time"
)

type fakeAliaser struct{}

func (fakeAliaser) Alias(kind, stableID string) string { return "alias-" + stableID }

func TestProviderSummaryReturnsAliasedRow(t *testing.T) {
	store := NewMemoryStore()
	store.SeedReliability(ReliabilityRow{
		ProviderID:    "real-id",
		WindowDays:    14,
		UptimePct:     0.987,
		SessionsCount: 12,
		MedianSessionSeconds: 4200,
		UpdatedAt:     time.Now(),
	})

	svc := NewService(store, fakeAliaser{}, time.Now)
	got, err := svc.ProviderSummary(context.Background(), "real-id")
	if err != nil {
		t.Fatalf("ProviderSummary: %v", err)
	}
	if got == nil {
		t.Fatalf("expected summary, got nil")
	}
	if got.Alias != "alias-real-id" {
		t.Fatalf("expected aliased id, got %q", got.Alias)
	}
	if got.UptimePct != 0.987 {
		t.Fatalf("uptime mismatch: %v", got.UptimePct)
	}
}

func TestProviderSummaryMissingReturnsNil(t *testing.T) {
	store := NewMemoryStore()
	svc := NewService(store, fakeAliaser{}, time.Now)
	got, err := svc.ProviderSummary(context.Background(), "unknown")
	if err != nil {
		t.Fatalf("ProviderSummary: %v", err)
	}
	if got != nil {
		t.Fatalf("expected nil for unknown provider, got %+v", got)
	}
}

func TestReliableProvidersHonorsFilters(t *testing.T) {
	store := NewMemoryStore()
	store.SeedReliability(ReliabilityRow{ProviderID: "good", UptimePct: 0.99, PStays4h: 0.9, PStays8h: 0.8})
	store.SeedReliability(ReliabilityRow{ProviderID: "ok", UptimePct: 0.80, PStays4h: 0.6, PStays8h: 0.3})
	store.SeedReliability(ReliabilityRow{ProviderID: "bad", UptimePct: 0.20, PStays4h: 0.1, PStays8h: 0.0})

	svc := NewService(store, fakeAliaser{}, time.Now)
	out, err := svc.ReliableProviders(context.Background(), ReliabilityFilterInput{
		MinUptimePct: 0.95,
		MinPStays4h:  0.85,
	})
	if err != nil {
		t.Fatalf("ReliableProviders: %v", err)
	}
	if len(out) != 1 || out[0].Alias != "alias-good" {
		t.Fatalf("expected only 'good' provider, got %+v", out)
	}
}

func TestFleetAvailabilityPercentiles(t *testing.T) {
	store := NewMemoryStore()
	for _, pct := range []float64{0.1, 0.5, 0.9, 0.95, 0.99} {
		store.SeedReliability(ReliabilityRow{
			ProviderID: "p-" + formatFloat(pct),
			WindowDays: 14,
			UptimePct:  pct,
		})
	}
	svc := NewService(store, fakeAliaser{}, time.Now)
	fa, err := svc.FleetAvailability(context.Background())
	if err != nil {
		t.Fatalf("FleetAvailability: %v", err)
	}
	if fa.Providers != 5 {
		t.Fatalf("expected 5 providers, got %d", fa.Providers)
	}
	// Two of five are >= 0.95 → highly_reliable = 2.
	if fa.HighlyReliable != 2 {
		t.Fatalf("highly_reliable: want 2, got %d", fa.HighlyReliable)
	}
	if fa.MeanUptimePct <= 0 || fa.MeanUptimePct > 1 {
		t.Fatalf("mean out of range: %v", fa.MeanUptimePct)
	}
}

func TestParseWindow(t *testing.T) {
	cases := map[string]Window{
		"":    Window7d,
		"7d":  Window7d,
		"24h": Window24h,
		"30d": Window30d,
	}
	for raw, expected := range cases {
		got, err := ParseWindow(raw)
		if err != nil {
			t.Fatalf("ParseWindow(%q) returned error: %v", raw, err)
		}
		if got != expected {
			t.Fatalf("ParseWindow(%q): want %q got %q", raw, expected, got)
		}
	}
	if _, err := ParseWindow("90d"); err == nil {
		t.Fatalf("expected error for unsupported window")
	}
}

func formatFloat(f float64) string {
	switch f {
	case 0.1:
		return "0.1"
	case 0.5:
		return "0.5"
	case 0.9:
		return "0.9"
	case 0.95:
		return "0.95"
	case 0.99:
		return "0.99"
	}
	return "x"
}
