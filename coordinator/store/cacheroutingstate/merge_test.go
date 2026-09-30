package cacheroutingstate

import (
	"testing"
	"time"
)

func TestLaterKeepsNewerColumnsAndLongestExpiry(t *testing.T) {
	now := time.Now()
	older := HolderRecord{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 999, UpdatedAt: now.Add(-time.Minute), ExpiresAt: now.Add(45 * time.Minute)}
	newer := HolderRecord{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 80, UpdatedAt: now, ExpiresAt: now.Add(29 * time.Minute)}
	for _, got := range []HolderRecord{Later(older, newer), Later(newer, older)} {
		if got.StageMs != 80 || !got.UpdatedAt.Equal(now) || !got.ExpiresAt.Equal(older.ExpiresAt) {
			t.Fatalf("merge order must not matter: %+v", got)
		}
	}
}

func TestDedupeHoldersAndDemand(t *testing.T) {
	now := time.Now()
	h := DedupeHolders([]HolderRecord{
		{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 1, UpdatedAt: now, ExpiresAt: now.Add(time.Minute)},
		{Key: "k", CacheEpoch: "e", ModelID: "m", StageMs: 2, UpdatedAt: now.Add(time.Second), ExpiresAt: now.Add(time.Minute)},
		{Key: "k2", CacheEpoch: "e", ModelID: "m", UpdatedAt: now, ExpiresAt: now.Add(time.Minute)},
	})
	if len(h) != 2 || h[0].StageMs != 2 {
		t.Fatalf("holder dedupe: %+v", h)
	}
	d := DedupeDemand([]DemandRecord{{Key: "a", SeenAt: now}, {Key: "a", SeenAt: now.Add(time.Second)}, {Key: "b", SeenAt: now}})
	if len(d) != 2 || !d[0].SeenAt.Equal(now.Add(time.Second)) {
		t.Fatalf("demand dedupe: %+v", d)
	}
	if (HolderRecord{Key: "k"}).Validate() == nil || (DemandRecord{}).Validate() == nil {
		t.Fatal("invalid records must be rejected")
	}
}
