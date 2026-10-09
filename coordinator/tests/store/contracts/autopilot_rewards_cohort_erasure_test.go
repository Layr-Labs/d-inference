package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestAutopilotRewardsCohortExcludesSoftDeletedPeers(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		deleted := erasurefixture.SeedAccount(t, f.backend)
		observeAutopilotCohortMachine(t, f, "deleted-peer", deleted.AccountID, "Apple M4 Max", 64, f.start)
		f.earning(t, "deleted-peer", deleted.AccountID, 70000, f.optIn.Add(-48*time.Hour))
		observeAutopilotCohortMachine(t, f, "live-peer", "live-owner", "Apple M4 Max", 64, f.start)
		f.earning(t, "live-peer", "live-owner", 70, f.optIn.Add(-48*time.Hour))
		erasurefixture.PlanAndConfirm(t, f.backend, deleted, time.UnixMicro(f.clock.Load()), time.Hour)
		young := f.optIn.Add(-time.Hour)
		observeAutopilotCohortMachine(t, f, "new", "owner", "Apple M4 Max", 64, young)
		f.consent(t, "new", "owner", false, young)
		e := f.consent(t, "new", "owner", true, f.optIn)
		if !e.BaselineKnown || e.BaselineSource != earningsfloor.CohortBaseline || e.SevenDayEarningsMicroUSD != 70 || e.DailyFloorMicroUSD != 11 {
			t.Fatalf("deleted peer changed cohort: %+v", e)
		}
	})
}
