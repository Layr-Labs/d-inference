package network

import (
	"context"
	"testing"
	"time"
)

func TestCacheRefreshLoopCancelledBeforeStart(t *testing.T) {
	srv, _, _ := newStatsRefresherFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	srv.runCacheRefreshLoop(ctx, time.Minute, func() { t.Fatal("queried after shutdown") })
}
