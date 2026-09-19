package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func buildAccountAffinityReserveBenchFleet(tb testing.TB, mode string) *Registry {
	tb.Helper()
	r := buildReserveBenchFleet(tb)
	for _, p := range r.providers {
		p.mu.Lock()
		p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "affinity-" + p.ID}
		p.mu.Unlock()
	}
	if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: mode, MaxTTFTPenaltyMs: 250}); err != nil {
		tb.Fatal(err)
	}
	return r
}

// Include identity snapshots, ranking, final admission and pending release,
// not just the allocation-free pure policy. Enabling affinity must not bring
// back one allocation per scanned provider to the arena-backed scheduler.
func TestAccountAffinityReserveAllocBudget(t *testing.T) {
	if testing.Short() {
		t.Skip("alloc budget check skipped in -short mode")
	}
	for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn} {
		t.Run(mode, func(t *testing.T) {
			r := buildAccountAffinityReserveBenchFleet(t, mode)
			allocs := testing.AllocsPerRun(200, func() {
				model, pr := reserveBenchRequest(1)
				pr.ConsumerKey = "benchmark-account"
				p, decision := r.ReserveProviderEx(model, pr)
				if p == nil || decision.AccountAffinity.Applied != (mode == AccountAffinityOn) ||
					decision.AccountAffinity.Evaluated != (mode != AccountAffinityOff) {
					t.Fatal("fixture did not exercise the configured reservation policy")
				}
				p.RemovePending(pr.RequestID)
			})
			t.Logf("ReserveProviderEx affinity %s: %.1f allocs/op (ceiling %d)", mode, allocs, reserveBenchMaxAllocs)
			if allocs > float64(reserveBenchMaxAllocs) {
				t.Fatalf("enabled affinity exceeded the scheduler allocation budget: %.1f > %d", allocs, reserveBenchMaxAllocs)
			}
		})
	}
}

func BenchmarkAccountAffinityReserve_350x2(b *testing.B) {
	for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn} {
		b.Run(mode, func(b *testing.B) {
			r := buildAccountAffinityReserveBenchFleet(b, mode)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				model, pr := reserveBenchRequest(i)
				pr.ConsumerKey = "benchmark-account"
				p, decision := r.ReserveProviderEx(model, pr)
				if p == nil || decision.AccountAffinity.Applied != (mode == AccountAffinityOn) {
					b.Fatal("fixture did not exercise the configured reservation policy")
				}
				p.RemovePending(pr.RequestID)
			}
		})
	}
}
