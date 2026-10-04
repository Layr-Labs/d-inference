package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
)

func TestExemptClockTimerDoesNotAllocate(t *testing.T) {
	clock := firstcontent.NewClock(time.Now().Add(-20*time.Minute), 0, time.Second)
	allocations := testing.AllocsPerRun(100, func() {
		timer := clock.Timer(clock.Wait(600 * time.Second))
		timer.Stop()
	})
	if allocations != 0 {
		t.Fatalf("exempt timer allocated %v times, want zero", allocations)
	}
}
