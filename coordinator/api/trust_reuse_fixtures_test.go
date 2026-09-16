package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

// setTrustReuseClock replaces only a fresh fixture's unseeded owner. Clock
// controls stay construction inputs; the owner exposes no mutable state.
func setTrustReuseClock(t *testing.T, s *Server, now func() time.Time) {
	t.Helper()
	s.trustReuse.StopCoverage()
	s.trustReuse.StopReplay()
	s.trustReuse.ReleaseAuthority()
	deps := s.trustReuseDependencies()
	deps.Now = now
	s.trustReuse = trustreuse.New(trustreuse.Config{}, deps)
	s.trustReuse.StopCoverage() // tests drive the coverage boundary explicitly
}

// seedTrustReuseRecord exercises the actual store/startup boundary instead of
// reaching into the owner's cache. All calls occur during fixture setup.
func seedTrustReuseRecord(t *testing.T, s *Server, rec store.ProviderTrustReuse) {
	t.Helper()
	if result, err := s.store.UpsertProviderTrustReuse(context.Background(), rec, rec.RevocationGeneration); err != nil || !result.Applied {
		t.Fatalf("seed reusable evidence: applied=%v err=%v", result.Applied, err)
	}
	if err := s.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("seed trust owner: %v", err)
	}
}
func hasReusableTrust(s *Server, seKey, serial, hash string) bool {
	return s.trustReuse.Assess(trustreuse.Input{SEPubKey: seKey, Serial: serial, FreshBinaryHash: hash}).Decision != ""
}

// This fleet control only assesses freshly seeded records at the same instant;
// all expiry/window variations live with the private cache's tests.
func trustReuseAssessmentForRecords(t *testing.T, now time.Time, rows []store.ProviderTrustReuse) *trustreuse.Manager {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	for _, rec := range rows {
		if result, err := st.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil || !result.Applied {
			t.Fatalf("seed fleet assessment: applied=%v err=%v", result.Applied, err)
		}
	}
	m := trustreuse.New(trustreuse.Config{}, trustreuse.Dependencies{
		Registry: registry.New(logger), Logger: logger, Now: func() time.Time { return now },
		NormalizeHash: normalizeSHA256Hex, MDMConfigured: func() bool { return false },
		SendStatus:     func(*registry.Provider, registry.TrustLevel, string, string) {},
		RecordDecision: func(trustreuse.Decision, trustreuse.Reason) {}, AfterCoverageSweep: func() {},
	})
	m.StopCoverage()
	t.Cleanup(m.StopReplay)
	t.Cleanup(m.ReleaseAuthority)
	if err := m.Seed(context.Background(), st); err != nil {
		t.Fatalf("seed fleet assessment: %v", err)
	}
	return m
}
