package analyticssnapshot

import (
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
