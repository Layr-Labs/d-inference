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
// Compare identical attested fleets: current upstream's verified-provider
// routing already allocates more than the unverified reserve-bench fixture.
// Affinity itself must add ZERO allocations above that off-mode baseline.
func TestAccountAffinityReserveAllocBudget(t *testing.T) {
	if testing.Short() {
		t.Skip("alloc budget check skipped in -short mode")
	}
	measureAllocs := func(t *testing.T, mode string) float64 {
		t.Helper()
		r := buildAccountAffinityReserveBenchFleet(t, mode)
		return testing.AllocsPerRun(200, func() {
			model, pr := reserveBenchRequest(1)
			pr.ConsumerKey = "benchmark-account"
			p, decision := r.ReserveProviderEx(model, pr)
			if p == nil || decision.AccountAffinity.Applied != (mode == AccountAffinityOn) ||
				decision.AccountAffinity.Evaluated != (mode != AccountAffinityOff) {
				t.Fatal("fixture did not exercise the configured reservation policy")
			}
			p.RemovePending(pr.RequestID)
		})
	}
	// Measure outside subtests so a focused -run selecting only on or shadow
	// still compares against a real off baseline.
	offAllocs := measureAllocs(t, AccountAffinityOff)
	for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn} {
		t.Run(mode, func(t *testing.T) {
			allocs := measureAllocs(t, mode)
			t.Logf("ReserveProviderEx affinity %s: %.1f allocs/op (same-fleet off baseline %.1f)", mode, allocs, offAllocs)
			if allocs > offAllocs {
				t.Fatalf("affinity added allocations above the same-fleet off baseline: %.1f > %.1f", allocs, offAllocs)
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
