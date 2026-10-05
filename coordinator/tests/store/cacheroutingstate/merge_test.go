package cacheroutingstate_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func TestLaterKeepsNewerColumnsAndLongestExpiry(t *testing.T) {
	now := time.Now()
	older := production.HolderRecord{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 999, UpdatedAt: now.Add(-time.Minute), ExpiresAt: now.Add(45 * time.Minute)}
	newer := production.HolderRecord{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 80, UpdatedAt: now, ExpiresAt: now.Add(29 * time.Minute)}
	for _, got := range []production.HolderRecord{production.Later(older, newer), production.Later(newer, older)} {
		if got.StageMs != 80 || !got.UpdatedAt.Equal(now) || !got.ExpiresAt.Equal(older.ExpiresAt) {
			t.Fatalf("merge order must not matter: %+v", got)
		}
	}
}

func TestDedupeHoldersAndDemand(t *testing.T) {
	now := time.Now()
	h := production.DedupeHolders([]production.HolderRecord{
		{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 1, UpdatedAt: now, ExpiresAt: now.Add(time.Minute)},
		{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 2, UpdatedAt: now.Add(time.Second), ExpiresAt: now.Add(time.Minute)},
		{Key: "k2", CacheEpoch: "e", ModelID: "m", UpdatedAt: now, ExpiresAt: now.Add(time.Minute)},
	})
	if len(h) != 2 || h[0].StageMs != 2 {
		t.Fatalf("holder dedupe: %+v", h)
	}
	d := production.DedupeDemand([]production.DemandRecord{{Key: "a", SeenAt: now}, {Key: "a", SeenAt: now.Add(time.Second)}, {Key: "b", SeenAt: now}})
	if len(d) != 2 || !d[0].SeenAt.Equal(now.Add(time.Second)) {
		t.Fatalf("demand dedupe: %+v", d)
	}
	if (production.HolderRecord{Key: "k"}).Validate() == nil || (production.DemandRecord{}).Validate() == nil {
		t.Fatal("invalid records must be rejected")
	}
}
