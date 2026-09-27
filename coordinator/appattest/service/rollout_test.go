package service

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestRolloutProtectsReleasedClientsAndRequiresOptIn(t *testing.T) {
	for _, version := range []string{"", "bogus", "0.9.3", "0.9.4-dev.1", "0.8.99"} {
		if got := appAttestRolloutDecision(version, "account", "machine", 100); got != "provider_upgrade_required" {
			t.Fatalf("%s: %s", version, got)
		}
	}
	for _, percent := range []int{-1, 0, 101} {
		if appAttestRolloutDecision("0.9.4", "account", "machine", percent) == "enabled" {
			t.Fatal("invalid or disabled rollout enabled")
		}
	}
	if appAttestRolloutDecision("0.9.4", "", "machine", 100) == "enabled" {
		t.Fatal("anonymous enrollment enabled")
	}
	for i := 0; i < 100; i++ {
		machine := strings.Repeat("m", i+1)
		if appAttestRolloutDecision("0.9.4", "a", machine, 100) != "enabled" {
			t.Fatal("full rollout excluded safe client")
		}
		if appAttestRolloutDecision("0.9.4", "a", machine, 10) == "enabled" && appAttestRolloutDecision("0.9.4", "a", machine, 20) != "enabled" {
			t.Fatal("cohort shrank when percentage increased")
		}
	}
	for percent := 1; percent <= 99; percent++ {
		if appAttestRolloutDecision("0.9.4", "same-account", "first-provisional", percent) != appAttestRolloutDecision("0.9.4", "same-account", "replacement-provisional", percent) {
			t.Fatal("reconnect rerolled account cohort")
		}
	}
	t.Setenv("EIGENINFERENCE_APP_ATTEST_SHADOW", "")
	t.Setenv("EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT", "")
	if c := ConfigFromEnvironment(); c.Enabled || c.RolloutPercent != 0 {
		t.Fatal("rollout must default off")
	}
}

func TestAppAttestRecoveryRotatesSessionAndReloadsWithoutDisconnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	x := &Session{s: &Service{logger: logger}, provider: &registry.Provider{ID: "serving"}, id: "old", key: &store.AppAttestShadowKey{KeyID: "cached"}}
	attempts := 0
	previous := x.id
	var delays []time.Duration
	x.runRecovering(context.Background(), func(context.Context) {
		attempts++
		if attempts > 1 {
			if x.id == previous || x.key != nil {
				t.Fatal("retry reused session or uncertain credential state")
			}
			previous = x.id
		}
		if attempts < 4 {
			x.lastOutcome = "storage_error"
		} else {
			x.lastOutcome = "signature"
		}
	}, func(_ context.Context, d time.Duration) bool { delays = append(delays, d); return true })
	if attempts != 4 || len(delays) != 3 || delays[0] != time.Minute || delays[1] != 5*time.Minute || delays[2] != time.Hour {
		t.Fatalf("attempts=%d delays=%v", attempts, delays)
	}
	for _, fatal := range []string{"signature", "counter_replay", "app_identity", "key_owner_or_policy", "unsupported", "not_configured"} {
		if retryableAppAttestOutcome(fatal) {
			t.Fatalf("retrying permanent rejection %s", fatal)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if waitAppAttestRetry(ctx, time.Hour) {
		t.Fatal("shutdown did not cancel recovery")
	}
}

func TestAppAttestSendFailureSchedulesFreshRecovery(t *testing.T) {
	x := &Session{s: &Service{}, provider: &registry.Provider{ID: "provider"}, id: "first"}
	attempts, waits := 0, 0
	x.runRecovering(context.Background(), func(ctx context.Context) {
		attempts++
		if attempts == 1 {
			// All enqueue failures, including a saturated control lane, take
			// send's same failure path. A stopped writer supplies that error here.
			if x.send(ctx, "prepare") || x.lastOutcome != "send_failed" {
				t.Fatal("send failure did not reach recovery")
			}
			return
		}
		if x.id == "first" || x.challenge != "" || x.expected != "" {
			t.Fatal("retry retained the failed send's challenge")
		}
		x.lastOutcome = "unsupported"
	}, func(_ context.Context, delay time.Duration) bool {
		waits++
		if delay != time.Minute {
			t.Fatalf("retry delay %s", delay)
		}
		return true
	})
	if attempts != 2 || waits != 1 {
		t.Fatalf("attempts=%d waits=%d", attempts, waits)
	}
}
