package recovery_test

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
)

func TestDriverFreshAssertionResetsOnlyConsecutiveFailureCadence(t *testing.T) {
	attempts := 0
	var delays []time.Duration
	var generations []string
	success := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	recovery.NewDriver(recovery.DriverDependencies{
		Attempt: func(_ context.Context, b recovery.Binding) recovery.Outcome {
			attempts++
			generations = append(generations, b.Session)
			o := recovery.Outcome{Reason: "storage_error"}
			if attempts >= 3 {
				o.AssertionAt = success
			}
			if attempts == 5 {
				o.Reason = "signature"
			}
			return o
		}, Wait: func(_ context.Context, delay time.Duration) bool { delays = append(delays, delay); return true },
	}, recovery.Binding{Session: "original"}).Run(context.Background())
	if !reflect.DeepEqual(delays, []time.Duration{time.Minute, 5 * time.Minute, time.Minute, 5 * time.Minute}) {
		t.Fatalf("fresh assertion cadence=%v", delays)
	}
	seen := map[string]bool{}
	for _, session := range generations {
		if session == "" || seen[session] {
			t.Fatalf("reused recovery generation %q", session)
		}
		seen[session] = true
	}
}

func TestDriverRebindsAfterCompletedWaitBeforeCancellationCheck(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	attempts := 0
	var rebound string
	recovery.NewDriver(recovery.DriverDependencies{
		Attempt: func(context.Context, recovery.Binding) recovery.Outcome {
			attempts++
			return recovery.Outcome{Reason: "timeout"}
		},
		Wait:   func(context.Context, time.Duration) bool { cancel(); return true },
		Rebind: func(b recovery.Binding) { rebound = b.Session },
	}, recovery.Binding{Session: "original"}).Run(ctx)
	if attempts != 1 || rebound == "" || rebound == "original" {
		t.Fatalf("attempts=%d rebound=%q", attempts, rebound)
	}
}

func TestDriverRotationRetryPrecedesEnrollmentBackoff(t *testing.T) {
	attempts, enrollments := 0, 0
	var delays []time.Duration
	recovery.NewDriver(recovery.DriverDependencies{
		Attempt: func(context.Context, recovery.Binding) recovery.Outcome {
			attempts++
			if attempts == 1 {
				return recovery.Outcome{Reason: "apple_invalid_key"}
			}
			return recovery.Outcome{Reason: "unsupported"}
		},
		RotationDue:   func(recovery.Outcome) bool { return true },
		EnrollmentDue: func(recovery.Outcome) bool { enrollments++; return true },
		Wait:          func(_ context.Context, delay time.Duration) bool { delays = append(delays, delay); return true },
	}, recovery.Binding{Session: "original"}).Run(context.Background())
	if len(delays) != 1 || delays[0] < 15*time.Second || delays[0] > 45*time.Second || enrollments != 0 {
		t.Fatalf("retry priorities: delays=%v enrollment reads=%d", delays, enrollments)
	}
}
