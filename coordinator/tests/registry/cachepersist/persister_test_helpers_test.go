package cachepersist_test

import (
	"context"
	"testing"
	"time"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// restoreForTest records the key generation so writes are unblocked, as the
// boot restore does in production.
func restoreForTest(t *testing.T, p interface {
	Restore(context.Context, time.Time, time.Duration, int, int) ([]crs.DemandRecord, error)
}, now time.Time) {
	t.Helper()
	if _, err := p.Restore(context.Background(), now, time.Minute, 1000, 0); err != nil {
		t.Fatalf("restore: %v", err)
	}
}

func rec(key, epoch string, now time.Time, ttl time.Duration) crs.HolderRecord {
	return crs.HolderRecord{Key: key, CacheEpoch: epoch, Tier: "ssd", ModelID: "model",
		AnchorTokenCount: 1024, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(ttl)}
}
