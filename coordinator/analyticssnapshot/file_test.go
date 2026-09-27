package analyticssnapshot

import (
	"bytes"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
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
