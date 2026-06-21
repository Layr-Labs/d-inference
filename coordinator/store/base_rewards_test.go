package store

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// storeBackends returns the store impls to exercise. MemoryStore always runs;
// PostgresStore runs only when DATABASE_URL is set (throwaway test DB).
func storeBackends(t *testing.T) map[string]Store {
	t.Helper()
	backends := map[string]Store{"memory": NewMemory(Config{})}
	if os.Getenv("DATABASE_URL") != "" {
		backends["postgres"] = testPostgresStore(t)
	}
	return backends
}

// TestCreditProviderAccount_DuplicateJobNoop is the regression for the
// double-credit bug (design §8 required fix). Crediting twice with the same
// job_id must leave balance, withdrawable, ledger history, and the earnings
// summary reflecting exactly one credit.
func TestCreditProviderAccount_DuplicateJobNoop(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct")
			earning := &ProviderEarning{
				AccountID:        acct,
				ProviderID:       "prov-1",
				ProviderKey:      uniqueID("pk"),
				JobID:            uniqueID("job"),
				Model:            "qwen3.5-9b",
				AmountMicroUSD:   123_000,
				PromptTokens:     10,
				CompletionTokens: 20,
			}
			if err := s.CreditProviderAccount(earning); err != nil {
				t.Fatalf("first credit: %v", err)
			}
			// Second credit with the same job_id must be a no-op.
			if err := s.CreditProviderAccount(earning); err != nil {
				t.Fatalf("second credit: %v", err)
			}

			if bal := s.GetBalance(acct); bal != 123_000 {
				t.Fatalf("balance = %d, want 123000 (single credit)", bal)
			}
			if w := s.GetWithdrawableBalance(acct); w != 123_000 {
				t.Fatalf("withdrawable = %d, want 123000 (single credit)", w)
			}
			if h := s.LedgerHistory(acct); len(h) != 1 {
				t.Fatalf("ledger history = %d, want 1", len(h))
			}
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatalf("summary: %v", err)
			}
			if sum.Count != 1 || sum.TotalMicroUSD != 123_000 {
				t.Fatalf("summary = %+v, want count=1 total=123000", sum)
			}
		})
	}
}

// TestSettleProviderFloorDraw_Idempotent settles the same (provider_key,
// epoch_id) twice; the second call must report credited=false and change
// nothing — one ledger entry, one draw row, balance unchanged.
func TestSettleProviderFloorDraw_Idempotent(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			pk := uniqueID("pk")
			acct := uniqueID("acct")
			epoch := "2026-05"
			draw := &ProviderFloorDraw{
				ProviderKey:    pk,
				AccountID:      acct,
				EpochID:        epoch,
				AmountMicroUSD: 18_000_000,
				FloorMicroUSD:  18_000_000,
				EarnedMicroUSD: 0,
				UptimeFrac:     1.0,
				MemoryGB:       64,
			}

			credited, err := s.SettleProviderFloorDraw(ctx, draw)
			if err != nil {
				t.Fatalf("first settle: %v", err)
			}
			if !credited {
				t.Fatalf("first settle credited=false, want true")
			}

			credited2, err := s.SettleProviderFloorDraw(ctx, draw)
			if err != nil {
				t.Fatalf("second settle: %v", err)
			}
			if credited2 {
				t.Fatalf("second settle credited=true, want false (idempotent)")
			}

			if bal := s.GetBalance(acct); bal != 18_000_000 {
				t.Fatalf("balance = %d, want 18000000 (single draw)", bal)
			}
			if w := s.GetWithdrawableBalance(acct); w != 18_000_000 {
				t.Fatalf("withdrawable = %d, want 18000000", w)
			}
			h := s.LedgerHistory(acct)
			floorEntries := 0
			for _, e := range h {
				if e.Type == LedgerFloorDraw {
					floorEntries++
				}
			}
			if floorEntries != 1 {
				t.Fatalf("floor-draw ledger entries = %d, want 1", floorEntries)
			}

			draws, err := s.ListFloorDrawsForEpoch(ctx, epoch)
			if err != nil {
				t.Fatalf("list draws: %v", err)
			}
			n := 0
			for _, d := range draws {
				if d.ProviderKey == pk {
					n++
				}
			}
			if n != 1 {
				t.Fatalf("draw rows for pk = %d, want 1", n)
			}

			total, err := s.SumFloorDrawsForEpoch(ctx, epoch)
			if err != nil {
				t.Fatalf("sum draws: %v", err)
			}
			if total != 18_000_000 {
				t.Fatalf("sum draws = %d, want 18000000", total)
			}
		})
	}
}

// TestSettleProviderFloorDraw_ZeroAmount asserts a zero-amount draw inserts the
// audit row (so the epoch is recorded as "settled, $0") but credits nothing.
func TestSettleProviderFloorDraw_ZeroAmount(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			pk := uniqueID("pk")
			acct := uniqueID("acct")
			epoch := "2026-05"
			draw := &ProviderFloorDraw{
				ProviderKey:    pk,
				AccountID:      acct,
				EpochID:        epoch,
				AmountMicroUSD: 0,
				FloorMicroUSD:  18_000_000,
				EarnedMicroUSD: 20_000_000, // out-earned the floor → $0 draw
				UptimeFrac:     1.0,
				MemoryGB:       64,
			}

			credited, err := s.SettleProviderFloorDraw(ctx, draw)
			if err != nil {
				t.Fatalf("settle: %v", err)
			}
			if !credited {
				t.Fatalf("zero-amount settle credited=false, want true (audit row inserted)")
			}

			if bal := s.GetBalance(acct); bal != 0 {
				t.Fatalf("balance = %d, want 0 (zero draw credits nothing)", bal)
			}
			if h := s.LedgerHistory(acct); len(h) != 0 {
				t.Fatalf("ledger history = %d, want 0", len(h))
			}

			draws, err := s.ListFloorDrawsForEpoch(ctx, epoch)
			if err != nil {
				t.Fatalf("list draws: %v", err)
			}
			found := false
			for _, d := range draws {
				if d.ProviderKey == pk {
					found = true
					if d.AmountMicroUSD != 0 {
						t.Fatalf("draw amount = %d, want 0", d.AmountMicroUSD)
					}
				}
			}
			if !found {
				t.Fatalf("zero-amount audit row not found")
			}

			// A re-settle of the same epoch is still idempotent.
			credited2, err := s.SettleProviderFloorDraw(ctx, draw)
			if err != nil {
				t.Fatalf("re-settle: %v", err)
			}
			if credited2 {
				t.Fatalf("re-settle credited=true, want false")
			}
		})
	}
}

// TestSumProviderEarningsByKey_Filters asserts the organic-earnings sum excludes
// base_reward credits, non-positive amounts, and rows outside [since,until).
func TestSumProviderEarningsByKey_Filters(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			pk := uniqueID("pk")
			acct := uniqueID("acct")
			base := time.Date(2026, 5, 15, 12, 0, 0, 0, time.UTC)
			since := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
			until := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

			mk := func(model string, amt int64, at time.Time) *ProviderEarning {
				return &ProviderEarning{
					AccountID:      acct,
					ProviderID:     "prov",
					ProviderKey:    pk,
					JobID:          uniqueID("job"),
					Model:          model,
					AmountMicroUSD: amt,
					CreatedAt:      at,
				}
			}

			// Organic, in-window — counted (10_000 + 5_000 = 15_000).
			if err := s.RecordProviderEarning(mk("qwen", 10_000, base)); err != nil {
				t.Fatal(err)
			}
			if err := s.RecordProviderEarning(mk("gemma", 5_000, base.Add(time.Hour))); err != nil {
				t.Fatal(err)
			}
			// Excluded: base_reward, zero amount, out-of-window (before/after).
			if err := s.RecordProviderEarning(mk("base_reward", 99_000, base)); err != nil {
				t.Fatal(err)
			}
			if err := s.RecordProviderEarning(mk("qwen", 0, base)); err != nil {
				t.Fatal(err)
			}
			if err := s.RecordProviderEarning(mk("qwen", 7_000, since.Add(-time.Hour))); err != nil {
				t.Fatal(err)
			}
			if err := s.RecordProviderEarning(mk("qwen", 7_000, until.Add(time.Hour))); err != nil {
				t.Fatal(err)
			}
			// Different provider key — must not leak in.
			other := mk("qwen", 50_000, base)
			other.ProviderKey = uniqueID("pk-other")
			other.JobID = uniqueID("job")
			if err := s.RecordProviderEarning(other); err != nil {
				t.Fatal(err)
			}

			total, err := s.SumProviderEarningsByKey(ctx, pk, since, until)
			if err != nil {
				t.Fatalf("sum: %v", err)
			}
			if total != 15_000 {
				t.Fatalf("sum = %d, want 15000", total)
			}
		})
	}
}

// TestListProviderSessionsOverlapping_BlueGreenDoubleOpen asserts two overlapping
// open sessions for one serial both surface (caller unions them) and that the
// union of covered time cannot exceed the epoch length.
func TestListProviderSessionsOverlapping_BlueGreenDoubleOpen(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			serial := uniqueID("SER")
			// Anchor the window on real time: OpenProviderSession stamps
			// connected_at = NOW(), so the epoch must contain "now".
			now := time.Now().UTC()
			start := now.Add(-1 * time.Hour)
			end := now.Add(30 * 24 * time.Hour)

			// Blue-green: two open rows for the SAME serial, both heartbeating
			// inside the epoch (the classic blue-green double-open).
			open1 := uniqueID("s1")
			open2 := uniqueID("s2")
			if err := s.OpenProviderSession(ctx, open1, serial, "acct"); err != nil {
				t.Fatal(err)
			}
			if err := s.OpenProviderSession(ctx, open2, serial, "acct"); err != nil {
				t.Fatal(err)
			}
			// Touch advances last_seen deterministically inside the window.
			if err := s.TouchProviderSession(ctx, open1, serial, "acct", "PK", now.Add(2*time.Hour)); err != nil {
				t.Fatal(err)
			}
			if err := s.TouchProviderSession(ctx, open2, serial, "acct", "PK", now.Add(72*time.Hour)); err != nil {
				t.Fatal(err)
			}

			sessions, err := s.ListProviderSessionsOverlapping(ctx, start, end, 90*time.Second)
			if err != nil {
				t.Fatalf("list overlapping: %v", err)
			}

			mine := 0
			for _, ps := range sessions {
				if ps.SerialNumber == serial {
					mine++
				}
			}
			if mine != 2 {
				t.Fatalf("overlapping sessions for serial = %d, want 2 (blue-green double-open)", mine)
			}

			// Union the covered intervals per machine; clamp open sessions to a
			// reasonable end. The union of two overlapping-or-disjoint intervals
			// within one month can never exceed the month length.
			covered := unionCoveredSeconds(sessions, serial, start, end)
			epochSeconds := end.Sub(start).Seconds()
			if covered > epochSeconds {
				t.Fatalf("union covered %.0fs exceeds epoch %.0fs (uptime > 1.0)", covered, epochSeconds)
			}
		})
	}
}

// TestListProviderSessionsOverlapping_Empty asserts an empty fleet returns a
// non-nil empty slice (no nil-panic in the caller).
func TestListProviderSessionsOverlapping_Empty(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			start := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
			end := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
			out, err := s.ListProviderSessionsOverlapping(ctx, start, end, 90*time.Second)
			if err != nil {
				t.Fatalf("list overlapping: %v", err)
			}
			if out == nil {
				t.Fatalf("empty fleet returned nil slice, want non-nil empty")
			}
			if len(out) != 0 {
				t.Fatalf("empty fleet returned %d sessions, want 0", len(out))
			}
		})
	}
}

// TestListProviderSessionsOverlapping_OpenSessionGraceIncludesOverlap covers the
// 5-minute settlement edge case where an open session's last_seen is just before
// the period but last_seen+grace overlaps it.
func TestListProviderSessionsOverlapping_OpenSessionGraceIncludesOverlap(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			serial := uniqueID("SER")
			sessionID := uniqueID("s")
			now := time.Now().UTC()
			start := now.Add(time.Minute)
			end := start.Add(5 * time.Minute)
			lastSeen := start.Add(-30 * time.Second)

			if err := s.OpenProviderSession(ctx, sessionID, serial, "acct"); err != nil {
				t.Fatal(err)
			}
			if err := s.TouchProviderSession(ctx, sessionID, serial, "acct", "PK", lastSeen); err != nil {
				t.Fatal(err)
			}

			withoutGrace, err := s.ListProviderSessionsOverlapping(ctx, start, end, 10*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			if countSessions(withoutGrace, serial) != 0 {
				t.Fatalf("session should not overlap with 10s grace")
			}

			withGrace, err := s.ListProviderSessionsOverlapping(ctx, start, end, 90*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			if countSessions(withGrace, serial) != 1 {
				t.Fatalf("session should overlap via 90s grace, got %d", countSessions(withGrace, serial))
			}
		})
	}
}

// TestSettleProviderFloorDraw_RecordsVisibleEarning is the regression for the
// "invisible payout" finding: a settled floor draw must show in the provider's
// earnings history + summary (as a base_reward row) so it isn't an unexplained
// balance jump — while staying EXCLUDED from organic draw math.
func TestSettleProviderFloorDraw_RecordsVisibleEarning(t *testing.T) {
	ctx := context.Background()
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			pk := uniqueID("pk")
			acct := uniqueID("acct")
			epoch := "2026-07"
			if _, err := s.SettleProviderFloorDraw(ctx, &ProviderFloorDraw{
				ProviderKey: pk, AccountID: acct, EpochID: epoch,
				AmountMicroUSD: 18_000_000, FloorMicroUSD: 18_000_000, UptimeFrac: 1.0, MemoryGB: 64,
			}); err != nil {
				t.Fatalf("settle: %v", err)
			}

			// Visible in earnings history as a base_reward row.
			earnings, err := s.GetAccountEarnings(acct, 10)
			if err != nil {
				t.Fatal(err)
			}
			var found bool
			for i := range earnings {
				if earnings[i].Model == "base_reward" && earnings[i].AmountMicroUSD == 18_000_000 {
					found = true
				}
			}
			if !found {
				t.Fatalf("floor draw not visible in account earnings: %+v", earnings)
			}

			// Counted in the displayed summary.
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.TotalMicroUSD != 18_000_000 || sum.Count != 0 {
				t.Fatalf("summary = %+v, want total 18000000 count 0 (base_reward is not a job)", sum)
			}

			// EXCLUDED from organic draw math: must not count toward earned.
			lo := time.Now().Add(-24 * time.Hour)
			hi := time.Now().Add(24 * time.Hour)
			organic, err := s.SumProviderEarningsByKey(ctx, pk, lo, hi)
			if err != nil {
				t.Fatal(err)
			}
			if organic != 0 {
				t.Fatalf("organic earnings = %d, want 0 (base_reward must be excluded)", organic)
			}
		})
	}
}

// --- test helpers ---

var idSeq int64

// uniqueID returns a process-unique identifier with the given prefix so the
// memory and postgres variants never collide across sub-tests.
func uniqueID(prefix string) string {
	idSeq++
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().UnixNano(), idSeq)
}

// unionCoveredSeconds clamps open sessions to `end`, then unions overlapping
// intervals for one serial and returns total covered seconds.
func unionCoveredSeconds(sessions []ProviderSession, serial string, start, end time.Time) float64 {
	type iv struct{ s, e time.Time }
	var ivs []iv
	for _, ps := range sessions {
		if ps.SerialNumber != serial {
			continue
		}
		s0 := ps.ConnectedAt
		if s0.Before(start) {
			s0 = start
		}
		e0 := ps.LastSeen
		if ps.DisconnectedAt != nil {
			e0 = *ps.DisconnectedAt
		}
		if e0.After(end) {
			e0 = end
		}
		if !e0.After(s0) {
			continue
		}
		ivs = append(ivs, iv{s0, e0})
	}
	// Sort by start (insertion sort — small N).
	for i := 1; i < len(ivs); i++ {
		for j := i; j > 0 && ivs[j].s.Before(ivs[j-1].s); j-- {
			ivs[j], ivs[j-1] = ivs[j-1], ivs[j]
		}
	}
	var total float64
	var curS, curE time.Time
	have := false
	for _, v := range ivs {
		if !have {
			curS, curE, have = v.s, v.e, true
			continue
		}
		if v.s.After(curE) {
			total += curE.Sub(curS).Seconds()
			curS, curE = v.s, v.e
		} else if v.e.After(curE) {
			curE = v.e
		}
	}
	if have {
		total += curE.Sub(curS).Seconds()
	}
	return total
}

func countSessions(sessions []ProviderSession, serial string) int {
	n := 0
	for _, ps := range sessions {
		if ps.SerialNumber == serial {
			n++
		}
	}
	return n
}
