package analyticssnapshot_test

import (
	. "github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"bytes"
	"fmt"
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
