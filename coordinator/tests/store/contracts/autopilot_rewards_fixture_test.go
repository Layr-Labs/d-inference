package store_test

import (
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgxpool"
)

type autopilotRewardsFixture struct {
	backend   store.Store
	rewards   store.AutopilotRewardsStore
	inventory store.MachineInventoryStore
	clock     atomic.Int64
	nowHook   func()
	start     time.Time
	optIn     time.Time
}

// Like storeBackends, this always exercises memory and includes PostgreSQL only
// with the isolated test database configured. A fresh database also isolates
// non-prunable receipts and the cumulative pool singleton between scenarios.
func autopilotRewardsBackends(t *testing.T, run func(*testing.T, *autopilotRewardsFixture)) {
	t.Helper()
	names := []string{"memory"}
	if os.Getenv("DATABASE_URL") != "" {
		names = append(names, "postgres")
	}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			f := &autopilotRewardsFixture{}
			trackingStart := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
			f.clock.Store(trackingStart.UnixMicro())
			config := store.Config{Now: func() time.Time {
				if f.nowHook != nil {
					f.nowHook()
				}
				return time.UnixMicro(f.clock.Load()).UTC()
			}}
			if name == "memory" {
				f.backend = memory.NewMemory(config)
			} else {
				config.DatabaseURL = newThrowawayTestDatabase(t)
				pg, err := postgres.NewPostgres(t.Context(), config)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(pg.Close)
				f.backend = pg
				// Keep campaign fixtures deterministic after the real end date.
				fixturePool, err := pgxpool.New(t.Context(), config.DatabaseURL)
				if err != nil {
					t.Fatal(err)
				}
				defer fixturePool.Close()
				if _, err := fixturePool.Exec(t.Context(), `UPDATE autopilot_reward_pool SET tracking_started_at=$1`, trackingStart); err != nil {
					t.Fatal(err)
				}
			}
			var ok bool
			f.rewards, ok = store.As[store.AutopilotRewardsStore](store.NewCached(f.backend, store.DefaultCacheConfig()))
			if !ok {
				t.Fatal("Autopilot reward capability is missing or hidden by cache")
			}
			f.inventory, ok = store.As[store.MachineInventoryStore](f.backend)
			if !ok {
				t.Fatal("machine inventory capability is missing")
			}
			pool, err := f.rewards.AutopilotRewardPool(t.Context())
			if err != nil || pool.TrackingStartedAt.IsZero() || pool.CapMicroUSD != 0 || pool.SpentMicroUSD != 0 {
				t.Fatalf("initial pool = %+v, %v", pool, err)
			}
			f.start = floorpolicy.Day(pool.TrackingStartedAt).AddDate(0, 0, 1)
			f.optIn = f.start.Add(8*24*time.Hour + 12*time.Hour)
			f.clock.Store(f.optIn.Add(40 * 24 * time.Hour).UnixMicro())
			run(t, f)
		})
	}
}

func (f *autopilotRewardsFixture) observe(t *testing.T, observation store.MachineObservation) store.MachineIdentity {
	t.Helper()
	machine, err := f.inventory.ObserveMachine(t.Context(), observation)
	if err != nil {
		t.Fatal(err)
	}
	return machine
}

func (f *autopilotRewardsFixture) consent(t *testing.T, session, account string, optedIn bool, at time.Time) earningsfloor.Enrollment {
	t.Helper()
	enrollment, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: session, AccountID: account, Supported: true, OptedIn: optedIn, At: at})
	if err != nil {
		t.Fatal(err)
	}
	return enrollment
}

func (f *autopilotRewardsFixture) earning(t *testing.T, session, account string, amount int64, at time.Time) {
	t.Helper()
	if err := f.backend.RecordProviderEarning(&store.ProviderEarning{
		AccountID: account, ProviderID: session, ProviderKey: session + "-key",
		JobID: uniqueID("autopilot-inference"), Model: "inference-model", AmountMicroUSD: amount,
		PromptTokens: 2, CompletionTokens: 3, CreatedAt: at,
	}); err != nil {
		t.Fatal(err)
	}
}

func (f *autopilotRewardsFixture) enroll(t *testing.T, session, account string, baseline int64) earningsfloor.Enrollment {
	t.Helper()
	f.observe(t, store.MachineObservation{SessionID: session, AccountID: account, SEKey: session + "-se", At: f.start})
	if initial := f.consent(t, session, account, false, f.start); initial.MachineID != "" {
		t.Fatalf("negative declaration created enrollment: %+v", initial)
	}
	if baseline != 0 {
		f.earning(t, session, account, baseline, f.optIn.Add(-48*time.Hour))
	}
	enrollment := f.consent(t, session, account, true, f.optIn)
	if !enrollment.BaselineKnown || enrollment.BaselineSource != earningsfloor.TrackedBaseline || enrollment.FirstOptInAt == nil || !enrollment.FirstOptInAt.Equal(f.optIn) || enrollment.SevenDayEarningsMicroUSD != baseline {
		t.Fatalf("enrollment = %+v, want original opt-in and baseline %d", enrollment, baseline)
	}
	return enrollment
}

func (f *autopilotRewardsFixture) fund(t *testing.T, cap int64) {
	t.Helper()
	if _, err := f.rewards.SetAutopilotRewardPoolCap(t.Context(), cap); err != nil {
		t.Fatal(err)
	}
}

func (f *autopilotRewardsFixture) settle(t *testing.T, machine string, day time.Time) earningsfloor.Settlement {
	t.Helper()
	receipt, err := f.rewards.SettleAutopilotRewardDay(t.Context(), machine, day)
	if err != nil {
		t.Fatal(err)
	}
	return receipt
}
