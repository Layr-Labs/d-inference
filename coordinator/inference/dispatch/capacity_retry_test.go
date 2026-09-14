package dispatch

import (
	"testing"
	"time"
)

func TestRetryAfterIncludesTimeBeyondTTFTTarget(t *testing.T) {
	srv := newTestController(t)
	threshold := DefaultFirstContentDeadlineBase
	if got := srv.estimateTTFTRetryAfter("no-queue", 8*time.Second, threshold); got != 3 {
		t.Fatalf("Retry-After without queue = %d, want 3s over target", got)
	}
}
