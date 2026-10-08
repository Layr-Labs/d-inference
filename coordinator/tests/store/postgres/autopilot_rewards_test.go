package postgres_test

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
)

type autopilotRewardsFixture struct {
	*postgresFixture
	now       time.Time
	firstSeen time.Time
}

func newAutopilotRewardsFixture(t *testing.T) *autopilotRewardsFixture {
	t.Helper()
	trackingStart := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
	f := &autopilotRewardsFixture{now: trackingStart.Add(40 * 24 * time.Hour)}
	var err error
	f.postgresFixture, err = openPostgresFixture(t.Context(), store.Config{DatabaseURL: newThrowawayTestDatabase(t), Now: func() time.Time { return f.now }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.Close)
	// Pin the campaign clock rather than aging these tests past its cutoff.
	if _, err := f.pool.Exec(t.Context(), `UPDATE autopilot_reward_pool SET tracking_started_at=$1`, trackingStart); err != nil {
		t.Fatal(err)
	}
	pool, err := f.AutopilotRewardPool(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	f.firstSeen = floorpolicy.Day(pool.TrackingStartedAt).Add(24 * time.Hour)
	return f
}

func (f *autopilotRewardsFixture) reopenRewards(t *testing.T) {
	t.Helper()
	f.PostgresStore.Close()
	s, err := production.NewPostgres(t.Context(), store.Config{DatabaseURL: f.pool.Config().ConnString(), Now: func() time.Time { return f.now }})
	if err != nil {
		t.Fatal(err)
	}
	f.PostgresStore = s
}

func (f *autopilotRewardsFixture) earning(t *testing.T, account, session, job, model string, amount int64, at time.Time) {
	t.Helper()
	if err := f.RecordProviderEarning(&store.ProviderEarning{AccountID: account, ProviderID: session, ProviderKey: "key:" + session,
		JobID: job, Model: model, AmountMicroUSD: amount, CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
}

func (f *autopilotRewardsFixture) enroll(t *testing.T, account, session string, first time.Time, sum int64) earningsfloor.Enrollment {
	t.Helper()
	ctx := t.Context()
	identity, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: session, AccountID: account, SEKey: session, At: f.firstSeen})
	if err != nil {
		t.Fatal(err)
	}
	if err := f.OpenProviderSession(ctx, session, "", account); err != nil {
		t.Fatal(err)
	}
	if err := f.TouchProviderSession(ctx, session, "", account, "key:"+session, f.firstSeen); err != nil {
		t.Fatal(err)
	}
	if empty, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: session, AccountID: account, Supported: true, At: f.firstSeen}); err != nil || empty.MachineID != "" {
		t.Fatalf("explicit initial off: %+v %v", empty, err)
	}
	f.earning(t, account, session, "baseline:"+session, "inference", sum, first.Add(-24*time.Hour))
	enrollment, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: session, AccountID: account, Supported: true, OptedIn: true, At: first})
	if err != nil || enrollment.MachineID != identity.ID || !enrollment.BaselineKnown || enrollment.SevenDayEarningsMicroUSD != sum {
		t.Fatalf("enroll: %+v %v", enrollment, err)
	}
	return enrollment
}

func TestAutopilotRewardsUnboundDeclarationSurvivesReopenAndOfflineBinding(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(12 * time.Hour)
	f.earning(t, "owner", "original", "baseline", "inference", 70, first.Add(-time.Hour))
	for _, declaration := range []earningsfloor.Consent{
		{SessionID: "original", AccountID: "owner", Supported: true, OptedIn: true, At: first},
		{SessionID: "original", AccountID: "owner", Supported: true, At: first.Add(time.Hour)},
	} {
		if _, err := f.ObserveAutopilotConsent(ctx, declaration); !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("unbound declaration: %v", err)
		}
	}
	f.reopenRewards(t)
	identity, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "original", AccountID: "owner", SEKey: "stable", At: first.Add(2 * time.Hour), Disconnected: true})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 {
		t.Fatalf("offline materialization: %+v %v", rows, err)
	}
	got := rows[0]
	if got.MachineID != identity.ID || !got.BaselineKnown || got.FirstOptInAt == nil || !got.FirstOptInAt.Equal(first) || !got.FirstObservedAt.Equal(first) || got.SevenDayEarningsMicroUSD != 70 || got.DailyFloorMicroUSD != 11 || got.OptedIn {
		t.Fatalf("lost original declaration or false transition: %+v", got)
	}
	f.reopenRewards(t)
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "reconnected", AccountID: "owner", SEKey: "stable", At: first.Add(24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	got, err = f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "reconnected", AccountID: "owner", Supported: true, OptedIn: true, At: first.Add(24 * time.Hour)})
	if err != nil || !got.FirstOptInAt.Equal(first) || got.DailyFloorMicroUSD != 11 {
		t.Fatalf("reconnect re-anchored baseline: %+v %v", got, err)
	}
	receipt, err := f.SettleAutopilotRewardDay(ctx, identity.ID, floorpolicy.Day(first))
	if err != nil || receipt.Status != earningsfloor.OptedOut || receipt.AmountMicroUSD != 0 {
		t.Fatalf("day-end false was lost after restart: %+v %v", receipt, err)
	}
}

func TestAutopilotRewardsPendingRecomputesAndCreditsOnceAfterReopen(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	enrollment := f.enroll(t, "owner", "provider", first, 70)
	day := floorpolicy.Day(first)
	f.earning(t, "owner", "provider", "actual", "sponsored-inference", 8, day.Add(time.Hour))
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 1); err != nil {
		t.Fatal(err)
	}
	initial, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, day)
	if err != nil || initial.Status != earningsfloor.PoolExhausted || initial.DueMicroUSD != 3 || initial.AmountMicroUSD != 0 {
		t.Fatalf("pending: %+v %v", initial, err)
	}
	f.now = f.now.Add(time.Hour)
	f.earning(t, "owner", "provider", "late", "inference", 1, day.Add(2*time.Hour))
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 2); err != nil {
		t.Fatal(err)
	}
	f.reopenRewards(t)
	paid, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, day)
	if err != nil || paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 2 || paid.InferenceMicroUSD != 9 || !paid.CreatedAt.Equal(initial.CreatedAt) {
		t.Fatalf("retry did not recompute full shortfall: %+v %v", paid, err)
	}
	f.reopenRewards(t)
	for range 3 {
		replay, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, day)
		if err != nil || replay != paid {
			t.Fatalf("replay: %+v %v", replay, err)
		}
	}
	pool, err := f.AutopilotRewardPool(ctx)
	if err != nil || pool.SpentMicroUSD != 2 || f.GetBalance("owner") != 2 || f.GetWithdrawableBalance("owner") != 2 {
		t.Fatalf("non-atomic accounting: %+v %v", pool, err)
	}
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 1); !errors.Is(err, earningsfloor.ErrPoolCap) {
		t.Fatalf("cap below spending accepted: %v", err)
	}
	var earningCount, ledgerCount int
	var key, job string
	var amount int64
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM provider_earnings WHERE model='base_reward'`).Scan(&earningCount); err != nil {
		t.Fatal(err)
	}
	if err := f.pool.QueryRow(ctx, `SELECT provider_key,job_id,amount_micro_usd FROM provider_earnings WHERE model='base_reward'`).Scan(&key, &job, &amount); err != nil {
		t.Fatal(err)
	}
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM ledger_entries WHERE entry_type=$1`, string(store.LedgerAutopilotFloor)).Scan(&ledgerCount); err != nil {
		t.Fatal(err)
	}
	if earningCount != 1 || ledgerCount != 1 || key != store.MachineFloorKey(enrollment.MachineID) || job != "autopilot-floor:"+enrollment.MachineID+":"+day.Format(time.DateOnly) || amount != 2 {
		t.Fatalf("credit duplication or attribution: earnings=%d ledger=%d key=%s job=%s amount=%d", earningCount, ledgerCount, key, job, amount)
	}
	summary, err := f.GetAccountEarningsSummary("owner")
	if err != nil || summary.Count != 3 || summary.TotalMicroUSD != 81 {
		t.Fatalf("reward counted as inference or counted twice: %+v %v", summary, err)
	}
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || !rows[0].NextDay.Equal(day.Add(24*time.Hour)) {
		t.Fatalf("cursor: %+v %v", rows, err)
	}
}

func TestAutopilotRewardsConcurrentCapAndDuplicateSettlement(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	enrollments := []earningsfloor.Enrollment{f.enroll(t, "first-owner", "a", first, 70), f.enroll(t, "second-owner", "b", first, 70)}
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 20); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errors := make(chan error, 16)
	start := make(chan struct{})
	for i := range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			receipt, err := f.SettleAutopilotRewardDay(ctx, enrollments[i%2].MachineID, floorpolicy.Day(first))
			if err == nil && receipt.Status != earningsfloor.Paid && receipt.Status != earningsfloor.PoolExhausted {
				err = fmt.Errorf("unexpected settlement %+v", receipt)
			}
			errors <- err
		}()
	}
	close(start)
	wg.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	pool, err := f.AutopilotRewardPool(ctx)
	if err != nil || pool.SpentMicroUSD != 11 || f.GetBalance("first-owner")+f.GetBalance("second-owner") != 11 {
		t.Fatalf("cap overspent or partially paid: %+v %v", pool, err)
	}
	var paid, pending int
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE status='paid'),count(*) FILTER (WHERE status='pool_exhausted') FROM autopilot_reward_settlements`).Scan(&paid, &pending); err != nil || paid != 1 || pending != 1 {
		t.Fatalf("duplicate or partial receipts: paid=%d pending=%d %v", paid, pending, err)
	}
}
