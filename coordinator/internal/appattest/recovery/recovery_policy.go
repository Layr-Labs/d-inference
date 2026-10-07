package recovery

import (
	"context"
	"time"
)

func Wait(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func RetryDelay(failures int) time.Duration {
	if failures == 0 {
		return time.Minute
	}
	if failures == 1 {
		return 5 * time.Minute
	}
	return time.Hour
}

func ExchangeRetryDelay(outcome string, failures int) time.Duration {
	// A previously accepted key can hit a client-reported Apple API failure
	// on a new connection. Probe at no more than the normal assertion cadence
	// while awaiting a fresh proof, without manufacturing trust from the error.
	// Keep the slower hourly cap for coordinator/storage failures.
	if outcome == "apple_error" || outcome == "apple_unavailable" {
		return min(RetryDelay(failures), AssertionInterval)
	}
	return RetryDelay(failures)
}

func RetryableOutcome(outcome string) bool {
	switch outcome {
	// Released clients collapse unknown DeviceCheck/system failures into
	// apple_error. It conveys no verified policy violation: retry with the
	// existing bounded backoff instead of abandoning this live connection.
	// A retry still needs fresh, fully qualified evidence before serving.
	case "timeout", "operation_timeout", "apple_unavailable", "apple_error", "busy", "storage_error", "enrollment_storage_error", "enrollment_expired", "write_failed", "send_failed", "storage_busy", "verifier_busy", "key_unregistered", "apple_invalid_key", "keychain_error", "challenge_mismatch":
		return true
	}
	return false
}
