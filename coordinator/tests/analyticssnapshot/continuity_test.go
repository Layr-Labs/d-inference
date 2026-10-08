package analyticssnapshot_test

import (
	"encoding/json"
	. "github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewGenerationMustAdvanceSourceCutoffs(t *testing.T) {
	// Stay away from bucket boundaries so metadata changes below preserve series bounds.
	now := time.Date(2026, 9, 27, 12, 0, 30, 0, time.UTC)
	for _, changed := range []string{"neither", "as_of_only", "source_only", "both"} {
		t.Run(changed, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "snapshot.json")
			write := func(s *Snapshot) {
				t.Helper()
				if err := os.WriteFile(path, data(t, s), 0600); err != nil {
					t.Fatal(err)
				}
			}
			first := fixture(now)
			first.SourceCompleteThrough = first.SourceCompleteThrough.Add(10 * time.Second)
			write(first)
			var c Cache
			if err := c.Load(path, now); err != nil {
				t.Fatal(err)
			}
			second := fixture(now)
			second.SourceCompleteThrough = second.SourceCompleteThrough.Add(10 * time.Second)
			second.Generation = "second"
			w := second.Windows["all"]
			w.Totals.EarningsMicroUSD, w.Totals.WorkEarningsMicroUSD = 5, 5
			second.Windows["all"] = w
			if changed == "as_of_only" || changed == "both" {
				second.AsOf = second.AsOf.Add(time.Second)
			}
			if changed == "source_only" || changed == "both" {
				second.SourceCompleteThrough = second.SourceCompleteThrough.Add(time.Second)
			}
			write(second)
			err := c.Load(path, now)
			if changed == "neither" {
				if err == nil {
					t.Fatal("accepted different generation without advancing a cutoff")
				}
				got, ok := c.Get(now)
				if !ok || got.Generation != first.Generation {
					t.Fatal("invalid refresh replaced the current generation")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := c.Load(path, now); err != nil {
				t.Fatal("identical generation must remain reloadable", err)
			}
			write(first)
			if err := c.Load(path, now); err == nil {
				t.Fatal("accepted pointer rollback")
			}
			got, ok := c.Get(now)
			if !ok || got.Generation != second.Generation || got.Windows["all"].Totals.EarningsMicroUSD != 5 {
				t.Fatal("pointer rollback replaced the accepted data")
			}
		})
	}
}

func TestGenerationReuseCannotRewriteAnEarlierIdentity(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 30, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "snapshot.json")
	statePath := filepath.Join(t.TempDir(), "accepted.json")
	if err := os.WriteFile(statePath, []byte(`{"version":1,"checksums":{}}`), 0600); err != nil {
		t.Fatal(err)
	}
	var cache Cache
	for i, generation := range []string{"first", "second", "first"} {
		s := fixture(now)
		s.Generation = generation
		s.AsOf = s.AsOf.Add(time.Duration(i) * time.Second)
		s.SourceCompleteThrough = s.AsOf
		if err := os.WriteFile(path, data(t, s), 0600); err != nil {
			t.Fatal(err)
		}
		err := cache.LoadPersistent(path, statePath, now)
		if i < 2 && err != nil {
			t.Fatal(err)
		}
		if i == 2 && err == nil {
			t.Fatal("accepted rewritten earlier generation with advanced cutoffs")
		}
	}
	got, ok := cache.Get(now)
	var accepted struct {
		Checksums map[string]string `json:"checksums"`
	}
	if err := json.Unmarshal(mustReadFile(t, statePath), &accepted); err != nil {
		t.Fatal(err)
	}
	if !ok || got.Generation != "second" || len(accepted.Checksums) != 2 {
		t.Fatal("reused generation altered accepted history")
	}
}
