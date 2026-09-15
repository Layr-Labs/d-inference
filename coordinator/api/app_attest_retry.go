package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"
)

// Retry transient shadow failures without reconnecting a serving provider.
// After three consecutive failures, probe once per hour. Every attempt has a
// new session/nonce, and the client retains its independent key-generation cap.
func (x *appAttestShadowSession) run(ctx context.Context) {
	x.runRecovering(ctx, x.runAttempt, waitAppAttestRetry)
}

func (x *appAttestShadowSession) runRecovering(ctx context.Context, attempt func(context.Context), wait func(context.Context, time.Duration) bool) {
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
		delay := appAttestRetryDelay(failures)
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

func retryableAppAttestOutcome(outcome string) bool {
	switch outcome {
	case "timeout", "operation_timeout", "apple_unavailable", "busy", "storage_error", "write_failed", "storage_busy", "verifier_busy", "key_unregistered", "apple_invalid_key", "keychain_error":
		return true
	}
	return false
}
