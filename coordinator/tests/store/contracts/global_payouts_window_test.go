package store_test

import (
	"context"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestGlobalPayoutPostedWindowStartsAtDispatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := store.As[store.GlobalPayoutStore](s)
			type windowCase struct {
				name                        string
				confirmedAgo, dispatchedAgo time.Duration
				legacy, missing, active     bool
			}
			cases := []windowCase{
				{name: "long_queue_recent_dispatch", confirmedAgo: 200 * 24 * time.Hour, dispatchedAgo: time.Minute, active: true},
				{name: "long_queue_expired_dispatch", confirmedAgo: 200 * 24 * time.Hour, dispatchedAgo: 91 * 24 * time.Hour},
				{name: "legacy_zero_recent", confirmedAgo: time.Minute, legacy: true, active: true},
				{name: "legacy_zero_expired", confirmedAgo: 91 * 24 * time.Hour, legacy: true},
			}
			var pool *pgxpool.Pool
			if name == "postgres" {
				var err error
				pool, err = pgxpool.New(context.Background(), os.Getenv("DATABASE_URL"))
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(pool.Close)
				cases = append(cases,
					windowCase{name: "legacy_missing_recent", confirmedAgo: time.Minute, legacy: true, missing: true, active: true},
					windowCase{name: "legacy_missing_expired", confirmedAgo: 91 * 24 * time.Hour, legacy: true, missing: true},
				)
			}
			for _, tc := range cases {
				t.Run(tc.name, func(t *testing.T) {
					now := time.Now().Truncate(time.Microsecond)
					p := payoutFixture(t, s, g, tc.name, "window-"+tc.name)
					confirmedAt := now.Add(-tc.confirmedAgo)
					if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, confirmedAt); err != nil {
						t.Fatal(err)
					}
					if !tc.legacy {
						if err := g.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{Status: "queued", FailureCode: store.WithdrawalFundingReason}, confirmedAt); err != nil {
							t.Fatal(err)
						}
						dispatchedAt := now.Add(-tc.dispatchedAgo)
						claimed, err := g.ClaimGlobalPayout(p.ID, dispatchedAt)
						if err != nil || claimed == nil {
							t.Fatalf("claim: %+v, %v", claimed, err)
						}
						if err := g.StartUnsentGlobalPayout(p.ID, claimed.LeaseUntil, p.Request, nil, p.DestinationAmount, dispatchedAt.Add(time.Minute), dispatchedAt); err != nil {
							t.Fatal(err)
						}
					}
					if err := g.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{Status: "posted", ExternalID: "obp_" + p.ID}, now); err != nil {
						t.Fatal(err)
					}
					if tc.missing {
						if _, err := pool.Exec(context.Background(), `UPDATE global_payout_withdrawals SET data=data-'dispatch_started_at' WHERE id=$1`, p.ID); err != nil {
							t.Fatal(err)
						}
					} else if tc.legacy && pool != nil {
						var started string
						if err := pool.QueryRow(context.Background(), `SELECT data->>'dispatch_started_at' FROM global_payout_withdrawals WHERE id=$1`, p.ID).Scan(&started); err != nil || started != "0001-01-01T00:00:00Z" {
							t.Fatalf("legacy zero JSON time = %q, %v", started, err)
						}
					}
					assertListed := func(at time.Time, want bool) {
						t.Helper()
						rows, err := g.ListGlobalPayoutsToReconcile(at, 200)
						if err != nil {
							t.Fatal(err)
						}
						listed := slices.ContainsFunc(rows, func(row store.GlobalPayout) bool { return row.ID == p.ID })
						if listed != want {
							t.Errorf("posted payout listed=%v at %s, want %v", listed, at, want)
						}
					}
					assertListed(now.Add(59*time.Second), false)
					assertListed(now.Add(time.Minute), tc.active)
					plan, err := s.PlanAccountErasure(context.Background(), p.AccountID, nil)
					wantOpen := int64(0)
					if tc.active {
						wantOpen = 1
					}
					if err != nil {
						t.Fatal(err)
					}
					if plan.OpenWithdrawals != wantOpen {
						t.Errorf("posted erasure protection = %d open withdrawals, want %d", plan.OpenWithdrawals, wantOpen)
					}
					claimed, err := g.ClaimGlobalPayout(p.ID, now)
					if err != nil || claimed == nil {
						t.Fatalf("readback claim: %+v, %v", claimed, err)
					}
					assertListed(now.Add(time.Minute), false)
					assertListed(now.Add(2*time.Minute), tc.active)
					if tc.active {
						windowStart := now.Add(-tc.dispatchedAgo)
						if tc.legacy {
							windowStart = confirmedAt
						}
						windowEnd := windowStart.Add(90 * 24 * time.Hour)
						assertListed(windowEnd.Add(-time.Microsecond), true)
						assertListed(windowEnd, false)
					}
					if b, w := s.GetBalanceWithWithdrawable(p.AccountID); b != 2_000_000 || w != b {
						t.Fatalf("window checks moved earnings: %d/%d", b, w)
					}
				})
			}
		})
	}
}
