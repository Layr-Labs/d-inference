package analyticssnapshot_test

import (
	"bytes"
	"fmt"
	. "github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func setRankingWindow(s *Snapshot, name string, accounts []store.LeaderboardRow, jobs int64) {
	w := Window{Totals: store.NetworkTotalsRow{ActiveAccounts: int64(len(accounts)), Jobs: jobs}, Leaderboards: map[string][]store.LeaderboardRow{}}
	for _, metric := range Metrics {
		w.Leaderboards[metric] = append([]store.LeaderboardRow{}, accounts...)
	}
	s.Windows[name] = w
}

func TestSnapshotRejectsDecreasingCountsInWiderWindow(t *testing.T) {
	for _, tc := range []struct {
		name, message         string
		narrowRows, widerRows []store.LeaderboardRow
		narrowJobs, widerJobs int64
	}{
		{
			name: "network jobs", message: "counts decrease",
			narrowRows: []store.LeaderboardRow{{AccountID: "a", Jobs: 1}},
			widerRows:  []store.LeaderboardRow{{AccountID: "a", Jobs: 1}},
			narrowJobs: 10, widerJobs: 9,
		},
		{
			name: "active accounts", message: "counts decrease",
			narrowRows: []store.LeaderboardRow{{AccountID: "a", Jobs: 1}, {AccountID: "b", Jobs: 1}},
			widerRows:  []store.LeaderboardRow{{AccountID: "a", Jobs: 1}},
			narrowJobs: 2, widerJobs: 2,
		},
		{
			name: "ranked account jobs", message: "account jobs decrease",
			narrowRows: []store.LeaderboardRow{{AccountID: "a", Jobs: 5}},
			widerRows:  []store.LeaderboardRow{{AccountID: "a", Jobs: 4}},
			narrowJobs: 5, widerJobs: 5,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now().UTC()
			s := fixture(now)
			setRankingWindow(s, "24h", tc.narrowRows, tc.narrowJobs)
			setRankingWindow(s, "7d", tc.widerRows, tc.widerJobs)
			for _, name := range []string{"30d", "all"} {
				setRankingWindow(s, name, tc.widerRows, 10)
			}
			_, err := Decode(bytes.NewReader(data(t, s)), now)
			if err == nil || !strings.Contains(err.Error(), tc.message) {
				t.Fatalf("expected %q, got %v", tc.message, err)
			}
		})
	}
}

func TestSnapshotAllowsAccountToLeaveWiderTop200(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	setRankingWindow(s, "24h", []store.LeaderboardRow{{AccountID: "a", Jobs: 1}}, 1)
	rows := make([]store.LeaderboardRow, 200)
	for i := range rows {
		rows[i] = store.LeaderboardRow{AccountID: fmt.Sprintf("b-%03d", i), Jobs: 1}
	}
	for _, name := range []string{"7d", "30d", "all"} {
		setRankingWindow(s, name, rows, 201)
		w := s.Windows[name]
		w.Totals.ActiveAccounts = 201
		s.Windows[name] = w
	}
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
		t.Fatalf("unranked narrow-window account must be allowed: %v", err)
	}
}

func TestDecodeRequiresNarrowAccountsInCompleteWiderCohort(t *testing.T) {
	for boundary := 1; boundary < len(Windows); boundary++ {
		for _, count := range []int{1, 200, 201} {
			t.Run(fmt.Sprintf("%s/accounts=%d", Windows[boundary], count), func(t *testing.T) {
				now := time.Now().UTC()
				s := fixture(now)
				rows := make([]store.LeaderboardRow, min(count, 200))
				for i := range rows {
					rows[i] = store.LeaderboardRow{AccountID: fmt.Sprintf("b-%03d", i), Jobs: 1}
				}
				for i, name := range Windows {
					if i < boundary {
						setRankingWindow(s, name, rows[:1], 1)
						continue
					}
					setRankingWindow(s, name, rows, int64(count))
					w := s.Windows[name]
					w.Totals.ActiveAccounts = int64(count)
					s.Windows[name] = w
				}
				if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
					t.Fatalf("valid contained cohort control: %v", err)
				}
				for _, name := range Windows[:boundary] {
					setRankingWindow(s, name, []store.LeaderboardRow{{AccountID: "z", Jobs: 1}}, 1)
				}
				_, err := Decode(bytes.NewReader(data(t, s)), now)
				if count > 200 {
					if err != nil {
						t.Fatalf("absent account is allowed in a truncated wider cohort: %v", err)
					}
				} else if err == nil || !strings.Contains(err.Error(), "account missing from complete wider cohort") {
					t.Fatalf("expected missing account rejection, got %v", err)
				}
			})
		}
	}
}

func TestSnapshotRejectsLifetimeJobsBelowThirtyDays(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	row := []store.LeaderboardRow{{AccountID: "a", Jobs: 1}}
	for _, name := range Windows {
		setRankingWindow(s, name, row, 10)
	}
	setRankingWindow(s, "all", row, 9)
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil || !strings.Contains(err.Error(), "counts decrease") {
		t.Fatalf("expected lifetime count rejection, got %v", err)
	}
}
