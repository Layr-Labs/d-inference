package inference_test

import (
	"context"
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
)

func TestAttemptLoopCancellationBetweenAttemptsPrecedesResetAndDispatch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var events []string
	loop := attempt.NewLoop(attempt.LoopOperations{
		Begin:         func(int) { events = append(events, "begin") },
		Expired:       func() bool { return false },
		ResetPreamble: func() { events = append(events, "reset") },
		Dispatch: func() attempt.SelectionResult {
			events = append(events, "dispatch")
			cancel()
			return attempt.SelectionResult{Outcome: attempt.Retry}
		},
		ClientGone: func() { events = append(events, "refund-and-record") },
	}, 64)
	result := loop.Run(ctx)
	if result.Outcome != attempt.ClientGone || result.LastAttempt != 1 {
		t.Fatalf("loop result = %+v, want client-gone at attempt 1", result)
	}
	if want := []string{"begin", "reset", "dispatch", "begin", "refund-and-record"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("operation order = %v, want %v", events, want)
	}
}

func TestAttemptLoopAcceptedRetryChecksPolicyBeforeNextAttempt(t *testing.T) {
	var events []string
	loop := attempt.NewLoop(attempt.LoopOperations{
		Begin:         func(int) { events = append(events, "begin") },
		Expired:       func() bool { return false },
		ResetPreamble: func() { events = append(events, "reset") },
		Dispatch:      func() attempt.SelectionResult { return attempt.SelectionResult{Outcome: attempt.Proceed} },
		Ready:         func() { events = append(events, "ready") },
		FirstContent:  func() attempt.Outcome { return attempt.Accepted },
		Accepted: func() attempt.Outcome {
			events = append(events, "accepted")
			return attempt.Retry
		},
		RetryDecision: func() retry.Decision {
			events = append(events, "policy")
			return retry.Decision{Stop: true}
		},
	}, 64)
	result := loop.Run(context.Background())
	if result.Outcome != attempt.FailFast || result.LastAttempt != 0 {
		t.Fatalf("loop result = %+v, want exhaustion at attempt 0", result)
	}
	if want := []string{"begin", "reset", "ready", "accepted", "policy"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("operation order = %v, want %v", events, want)
	}
}

func TestAttemptLoopExpiredInflightContentCommitsWithoutAnotherWait(t *testing.T) {
	loop := attempt.NewLoop(attempt.LoopOperations{
		Begin:           func(int) {},
		Expired:         func() bool { return true },
		ResetPreamble:   func() {},
		Dispatch:        func() attempt.SelectionResult { return attempt.SelectionResult{Outcome: attempt.Proceed} },
		Ready:           func() {},
		ExpiredInflight: func() attempt.Outcome { return attempt.Committed },
		FirstContent: func() attempt.Outcome {
			t.Fatal("buffered commitment must not enter the first-content wait")
			return attempt.FailFast
		},
	}, 64)
	result := loop.Run(context.Background())
	if result.Outcome != attempt.Committed || result.LastAttempt != 0 {
		t.Fatalf("loop result = %+v, want commitment at attempt 0", result)
	}
}
