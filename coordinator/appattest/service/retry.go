package service

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"
)

// Retry transient shadow failures without reconnecting a serving provider.
// After three consecutive failures, probe hourly for coordinator/storage
// errors and at the normal ten-minute assertion cadence for Apple API errors.
// Every attempt has a new session/nonce, and the client retains its independent
// key-generation cap.
func (x *Session) run(ctx context.Context) {
	x.runRecovering(ctx, x.runAttempt, waitAppAttestRetry)
}

func (x *Session) runRecovering(ctx context.Context, attempt func(context.Context), wait func(context.Context, time.Duration) bool) {
	for failures := 0; ctx.Err() == nil; failures++ {
		previousSuccess := x.assertionAt
		x.lastOutcome = ""
		attempt(ctx)
		failure := x.lastOutcome
		if ctx.Err() != nil {
			return
		}
		x.observeFailedPolicy(failure)
		if !retryableAppAttestOutcome(failure) {
			return
		}
		if x.assertionAt.After(previousSuccess) {
			failures = 0
		}
		delay := appAttestExchangeRetryDelay(failure, failures)
		x.observe("recovery", "retry_scheduled", nil)
		if !wait(ctx, delay) {
			return
		}
		var nonce [32]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			return
		}
		x.id = base64.StdEncoding.EncodeToString(nonce[:])
		x.expected, x.challenge, x.rejectReason = "", "", ""
		x.key = nil // Reload the durable counter/acceptance after uncertain writes.
	}
}

func waitAppAttestRetry(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func appAttestRetryDelay(failures int) time.Duration {
	if failures == 0 {
		return time.Minute
	}
	if failures == 1 {
		return 5 * time.Minute
	}
	return time.Hour
}

func appAttestExchangeRetryDelay(outcome string, failures int) time.Duration {
	// A previously accepted key can hit a client-reported Apple API failure
	// on a new connection. Probe at no more than the normal assertion cadence
	// while awaiting a fresh proof, without manufacturing trust from the error.
	// Keep the slower hourly cap for coordinator/storage failures.
	if outcome == "apple_error" || outcome == "apple_unavailable" {
		return min(appAttestRetryDelay(failures), shadowAssertionInterval)
	}
	return appAttestRetryDelay(failures)
}

// A verified first assertion with unavailable readiness or an enrollment
// receipt awaiting a verified risk receipt has no authorizer refresh record
// yet. Reuse the existing bounded backoff for a fresh assertion,
// capped at the normal cadence: one minute, five minutes, then ten minutes.
// A known decision or an existing refresh record restores the normal cadence.
// Only the serialized session worker reads or writes this retry state.
func (x *Session) nextAssertionDelay() time.Duration {
	if !x.readinessRetryPending {
		x.readinessRetryFailures = 0
		return shadowAssertionInterval
	}
	delay := min(appAttestRetryDelay(x.readinessRetryFailures), shadowAssertionInterval)
	if x.readinessRetryFailures < 2 {
		x.readinessRetryFailures++
	}
	return delay
}

func retryableAppAttestOutcome(outcome string) bool {
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
