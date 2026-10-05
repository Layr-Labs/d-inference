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

func TestIncompleteTopRanksAndCrossMetricDisagreementAreRejected(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	w.Totals.ActiveAccounts = 1
	w.Leaderboards["earnings"] = []store.LeaderboardRow{{AccountID: "a", Jobs: 1}}
	w.Leaderboards["tokens"] = []store.LeaderboardRow{{AccountID: "a", Jobs: 1}}
	w.Leaderboards["jobs"] = []store.LeaderboardRow{{AccountID: "a", Jobs: 2}}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil {
		t.Fatal("accepted cross-metric inconsistency")
	}
	w.Leaderboards["jobs"] = []store.LeaderboardRow{}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil {
		t.Fatal("accepted truncated ranking")
	}
}

func TestCompleteRankingsRequireIdenticalAccountSets(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	w.Totals.ActiveAccounts = 1
	w.Totals.Jobs = 1
	for i, metric := range Metrics {
		w.Leaderboards[metric] = []store.LeaderboardRow{{AccountID: fmt.Sprintf("account-%d", i), Jobs: 1}}
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil {
		t.Fatal("accepted three different cohorts in a complete ranking")
	}
	for _, metric := range Metrics {
		w.Leaderboards[metric] = []store.LeaderboardRow{{AccountID: "same-account", Jobs: 1}}
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
		t.Fatal(err)
	}
}

func TestPartialTopRankingsMayContainDifferentAccounts(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	w.Totals = store.NetworkTotalsRow{ActiveAccounts: 201, Jobs: 20100, Tokens: 20100, EarningsMicroUSD: 20100, WorkEarningsMicroUSD: 20100}
	rows := make([]store.LeaderboardRow, 201)
	for i := range rows {
		rows[i] = store.LeaderboardRow{AccountID: fmt.Sprintf("account-%03d", i), Jobs: int64(i), Tokens: int64(200 - i), EarningsMicroUSD: int64(i), WorkEarningsMicroUSD: int64(i)}
	}
	w.Leaderboards["tokens"] = append([]store.LeaderboardRow{}, rows[:200]...)
	for i := 200; i >= 1; i-- {
		w.Leaderboards["earnings"] = append(w.Leaderboards["earnings"], rows[i])
		w.Leaderboards["jobs"] = append(w.Leaderboards["jobs"], rows[i])
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
		t.Fatal(err)
	}
}

func TestDecodeRejectsTop200OmittingKnownHigherRank(t *testing.T) {
	for _, metric := range Metrics {
		for _, tied := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/tied=%v", metric, tied), func(t *testing.T) {
				now := time.Now().UTC()
				s := fixture(now)
				w := s.Windows["all"]
				w.Totals.ActiveAccounts = 201
				rows := make([]store.LeaderboardRow, 201)
				for i := range rows {
					r := store.LeaderboardRow{AccountID: fmt.Sprintf("account-%03d", i), Jobs: 1}
					if !tied {
						switch metric {
						case "tokens":
							r.Tokens = int64(100 - i)
						case "jobs":
							r.Jobs = int64(201 - i)
						case "earnings":
							r.EarningsMicroUSD = int64(100 - i)
							r.WorkEarningsMicroUSD = r.EarningsMicroUSD
						}
					}
					rows[i] = r
					w.Totals.Jobs += r.Jobs
					w.Totals.Tokens += r.Tokens
					w.Totals.EarningsMicroUSD += r.EarningsMicroUSD
					w.Totals.WorkEarningsMicroUSD += r.WorkEarningsMicroUSD
				}
				for _, board := range Metrics {
					w.Leaderboards[board] = rows[:200]
				}
				s.Windows["all"] = w
				if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
					t.Fatalf("valid top-200 control: %v", err)
				}
				// Still sorted and internally consistent, but another board exposes
				// the omitted account that outranks this board's last entry.
				w.Leaderboards[metric] = rows[1:]
				if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil || !strings.Contains(err.Error(), "omits a higher-ranked account") {
					t.Fatalf("expected omitted higher rank rejection, got %v", err)
				}
			})
		}
	}
}

func TestRankedJobCountsMustFitNetworkTotal(t *testing.T) {
	for _, tc := range []struct {
		name  string
		jobs  []int64
		total int64
		valid bool
	}{
		{"one account too large", []int64{2}, 1, false},
		{"sum too large", []int64{2, 2}, 3, false},
		{"sum overflows int64", []int64{1<<63 - 1, 1}, 1<<63 - 1, false},
		{"anonymous jobs allowed", []int64{2}, 3, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now().UTC()
			s := fixture(now)
			w := s.Windows["all"]
			w.Totals.ActiveAccounts, w.Totals.Jobs = int64(len(tc.jobs)), tc.total
			for _, metric := range Metrics {
				for i, jobs := range tc.jobs {
					w.Leaderboards[metric] = append(w.Leaderboards[metric], store.LeaderboardRow{AccountID: fmt.Sprintf("account-%d", i), Jobs: jobs})
				}
			}
			s.Windows["all"] = w
			_, err := Decode(bytes.NewReader(data(t, s)), now)
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v error=%v", tc.valid, err)
			}
		})
	}
}

func TestPartialRankingsCannotExceedReportedCohort(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	w.Totals.ActiveAccounts = 201
	for offset, metric := range Metrics {
		for i := 0; i < 200; i++ {
			w.Leaderboards[metric] = append(w.Leaderboards[metric], store.LeaderboardRow{AccountID: fmt.Sprintf("account-%03d", i+offset)})
		}
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil {
		t.Fatal("accepted 202 distinct ranked accounts in a cohort of 201")
	}
}

func TestAnonymousSignedCorrectionsDoNotCreateFalseCountBounds(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	// One named job contributes +10 money/+7 tokens, and one anonymous
	// correction contributes -15/-4. Both are counted as work events.
	w.Totals = store.NetworkTotalsRow{ActiveAccounts: 1, Jobs: 2, Tokens: 3, EarningsMicroUSD: -5, WorkEarningsMicroUSD: -5}
	for _, metric := range Metrics {
		w.Leaderboards[metric] = []store.LeaderboardRow{{AccountID: "a", Jobs: 1, Tokens: 7, EarningsMicroUSD: 10, WorkEarningsMicroUSD: 10}}
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
		t.Fatal("signed monetary/token adjustments must not be bounded like job counts", err)
	}
}

func TestSignedTokenCorrectionsRemainValid(t *testing.T) {
	now := time.Now().UTC()
	s := fixture(now)
	w := s.Windows["all"]
	w.Totals = store.NetworkTotalsRow{ActiveAccounts: 1, Jobs: 1, Tokens: -3}
	for _, metric := range Metrics {
		w.Leaderboards[metric] = []store.LeaderboardRow{{AccountID: "a", Jobs: 1, Tokens: -3}}
	}
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err != nil {
		t.Fatal("signed corrected token totals must be accepted", err)
	}
	w.Leaderboards["jobs"][0].Jobs = -1
	s.Windows["all"] = w
	if _, err := Decode(bytes.NewReader(data(t, s)), now); err == nil {
		t.Fatal("negative job count must still be rejected")
	}
}
