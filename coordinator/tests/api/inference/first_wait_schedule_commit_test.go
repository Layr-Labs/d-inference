package inference_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstWaitCommitsRefinedScheduleBeforeSpeculativeRouting(t *testing.T) {
	receivedAt := time.Now()
	advance := make(chan time.Time, 1)
	advance <- receivedAt.Add(20 * time.Millisecond)
	pending := &registry.PendingRequest{
		FirstContentDeadline: receivedAt.Add(time.Second),
		ChunkCh:              make(chan registry.ProviderChunk, 1),
	}
	committed := make(chan time.Duration, 1)
	deps := attempt.FirstWaitDependencies{
		Refine: func(at time.Duration) { committed <- at },
		Speculate: func() attempt.Outcome {
			select {
			case at := <-committed:
				if at != 20*time.Millisecond {
					t.Fatalf("committed schedule = %s, want 20ms", at)
				}
			default:
				t.Fatal("routing started before the refined schedule was committed")
			}
			return attempt.Retry
		},
		ClientGone: func() { t.Fatal("refined schedule never launched") },
	}
	waiter := attempt.NewFirstWait(deps, attempt.FirstWaitConfig{
		Pending: pending, Timing: &registry.RequestTiming{ReceivedAt: receivedAt},
		Deadline: time.Second, SpeculativeAt: 900 * time.Millisecond, HedgeAdvance: advance,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	var held []string
	if result := waiter.Run(ctx, &held); result.Outcome != attempt.Retry {
		t.Fatalf("wait result = %v, want routed retry", result.Outcome)
	}
}
