package analyticssnapshot

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func fixture(now time.Time) *Snapshot {
	s := &Snapshot{SchemaVersion: 1, Generation: "generation1", ReconciliationID: "verified1", SourceComplete: true, SourceCompleteThrough: now.Add(-time.Minute), AsOf: now.Add(-time.Minute), GeneratedAt: now, Windows: map[string]Window{}}
	for _, w := range Windows {
		s.Windows[w] = Window{Leaderboards: map[string][]store.LeaderboardRow{"earnings": {}, "tokens": {}, "jobs": {}}}
	}
	s.Series = map[string]Series{}
	for name, spec := range SeriesSpecs {
		end := s.AsOf.UTC().Truncate(spec.Bucket)
		s.Series[name] = Series{Start: end.Add(-spec.Lookback), End: end, BucketSeconds: int64(spec.Bucket / time.Second), Buckets: []store.UsageBucket{}}
	}
	return s
}
func data(t *testing.T, s *Snapshot) []byte {
	t.Helper()
	b, e := json.Marshal(s)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func TestSnapshotRejectsIncompleteStaleAndOverflow(t *testing.T) {
	now := time.Now().UTC()
	cases := map[string]func(*Snapshot){
		"partial":        func(s *Snapshot) { s.SourceComplete = false },
		"missing_window": func(s *Snapshot) { delete(s.Windows, "7d") },
		"missing_metric": func(s *Snapshot) { w := s.Windows["all"]; delete(w.Leaderboards, "jobs") },
		"stale_source": func(s *Snapshot) {
			s.SourceCompleteThrough = now.Add(-11 * time.Minute)
			s.AsOf = s.SourceCompleteThrough
		},
		"generated_before_watermark": func(s *Snapshot) {
			s.GeneratedAt = s.AsOf
			s.SourceCompleteThrough = s.AsOf.Add(30 * time.Second)
		},
		"old_asof": func(s *Snapshot) { s.AsOf = now.Add(-11 * time.Minute) },
		"future":   func(s *Snapshot) { s.SourceCompleteThrough = now.Add(time.Minute) },
		"overflow": func(s *Snapshot) {
			w := s.Windows["all"]
			w.Totals.EarningsMicroUSD = -1 << 63
			w.Totals.WorkEarningsMicroUSD = 1<<63 - 1
			w.Totals.RewardEarningsMicroUSD = 1
			s.Windows["all"] = w
		},
		"unordered": func(s *Snapshot) {
			w := s.Windows["all"]
			w.Leaderboards["jobs"] = []store.LeaderboardRow{{AccountID: "b", Jobs: 1}, {AccountID: "a", Jobs: 1}}
			w.Totals.ActiveAccounts = 2
			s.Windows["all"] = w
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			s := fixture(now)
			mutate(s)
			if _, e := Decode(bytes.NewReader(data(t, s)), now); e == nil {
				t.Fatal("accepted invalid snapshot")
			}
		})
	}
	if _, e := Decode(bytes.NewReader(data(t, fixture(now))), now); e != nil {
		t.Fatal(e)
	}
	if _, e := Decode(bytes.NewReader(append(data(t, fixture(now)), []byte("{}")...)), now); e == nil {
		t.Fatal("accepted trailing document")
	}
}
func TestCacheFailureKeepsFreshPriorButNeverStale(t *testing.T) {
	now := time.Now().UTC()
	path := filepath.Join(t.TempDir(), "snapshot.json")
	s := fixture(now)
	if e := os.WriteFile(path, data(t, s), 0600); e != nil {
		t.Fatal(e)
	}
	var c Cache
	if e := c.Load(path, now); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(path, []byte("broken"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := c.Load(path, now); e == nil {
		t.Fatal("accepted corrupt update")
	}
	if _, ok := c.Get(now); !ok {
		t.Fatal("lost valid prior")
	}
	if _, ok := c.Get(now.Add(11 * time.Minute)); ok {
		t.Fatal("served expired snapshot")
	}
	s.AsOf = s.AsOf.Add(-time.Second)
	s.Generation = "older"
	if e := os.WriteFile(path, data(t, s), 0600); e != nil {
		t.Fatal(e)
	}
	if e := c.Load(path, now); e == nil {
		t.Fatal("accepted regressing generation")
	}
}
