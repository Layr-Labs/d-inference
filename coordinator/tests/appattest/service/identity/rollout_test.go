package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestRecoveryRotatesSessionAndReloadsWithoutDisconnect(t *testing.T) {
	h := newRotationHarness(t, 0)
	x := h.exchange(3, &registry.Provider{ID: "serving"})
	x.attempt.Challenge.Binding.Session = "old"
	x.attempt.Challenge.Credential = &store.AppAttestShadowKey{KeyID: "cached"}
	attempts := 0
	previous := x.attempt.Challenge.Binding.Session
	var delays []time.Duration
	x.drive(context.Background(), func(_ context.Context, binding recovery.Binding) recovery.Outcome {
		attempts++
		if attempts > 1 {
			if binding.Session == previous || x.attempt.Challenge.Credential != nil {
				t.Fatal("retry reused session or uncertain credential state")
			}
			previous = binding.Session
		}
		if attempts < 4 {
			return recovery.Outcome{Reason: "storage_error"}
		} else {
			return recovery.Outcome{Reason: "signature"}
		}
	}, func(_ context.Context, d time.Duration) bool { delays = append(delays, d); return true }, nil)
	if attempts != 4 || len(delays) != 3 || delays[0] != time.Minute || delays[1] != 5*time.Minute || delays[2] != time.Hour {
		t.Fatalf("attempts=%d delays=%v", attempts, delays)
	}
	for _, fatal := range []string{"signature", "counter_replay", "app_identity", "key_owner_or_policy", "unsupported", "not_configured"} {
		if recovery.RetryableOutcome(fatal) {
			t.Fatalf("retrying permanent rejection %s", fatal)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if recovery.Wait(ctx, time.Hour) {
		t.Fatal("shutdown did not cancel recovery")
	}
}

func TestAppAttestSendFailureSchedulesFreshRecovery(t *testing.T) {
	h := newRotationHarness(t, 0)
	x := h.session(3)
	x.attempt.Challenge.Binding.Session = "first"
	attempts, waits := 0, 0
	x.drive(context.Background(), func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
		attempts++
		if attempts == 1 {
			// All enqueue failures, including a saturated control lane, take
			// send's same failure path. A stopped writer supplies that error here.
			result := exchange.Send(ctx, exchange.SendDependencies{Transport: x.provider.EnqueueText}, x.attempt.Challenge.Binding, x.attempt.Challenge.Credential, "prepare")
			x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge = result.Expected, result.Challenge
			if result.Sent || result.Outcome != "send_failed" {
				t.Fatal("send failure did not reach recovery")
			}
			return recovery.Outcome{Reason: result.Outcome}
		}
		if binding.Session == "first" || x.attempt.Challenge.Binding.Challenge != "" || x.attempt.Challenge.Expected != "" {
			t.Fatal("retry retained the failed send's challenge")
		}
		return recovery.Outcome{Reason: "unsupported"}
	}, func(_ context.Context, delay time.Duration) bool {
		waits++
		if delay != time.Minute {
			t.Fatalf("retry delay %s", delay)
		}
		return true
	}, nil)
	if attempts != 2 || waits != 1 {
		t.Fatalf("attempts=%d waits=%d", attempts, waits)
	}
}
