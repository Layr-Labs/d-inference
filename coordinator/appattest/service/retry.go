package service

import (
	"context"
	"time"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
)

// Retry transient shadow failures without reconnecting a serving provider.
// After three consecutive failures, probe hourly for coordinator/storage
// errors and at the normal ten-minute assertion cadence for Apple API errors.
// Every attempt has a new session/nonce, and the client retains its independent
// key-generation cap.
func (x *Session) run(ctx context.Context) {
	recovery.NewDriver(recovery.DriverDependencies{
		Attempt: func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
			x.lastOutcome, x.readyDiagnostics = "", nil
			x.keyRotation().BeginAttempt()
			x.runAttempt(ctx)
			return recovery.Outcome{Reason: x.lastOutcome, AssertionAt: x.assertionAt}
		},
		Rebind: func(binding recovery.Binding) {
			x.id = binding.Session
			x.expected, x.challenge, x.rejectReason = "", "", ""
			x.key = nil // Reload durable acceptance after uncertain writes.
		},
		Wait: recovery.Wait, BackoffRemaining: x.enrollmentBackoffRemaining,
		RotationDue:    func(o recovery.Outcome) bool { return x.rotationRetryDue(o.Reason) },
		EnrollmentDue:  func(o recovery.Outcome) bool { return x.enrollmentBackoffDue(o.Reason) },
		ObserveFailure: x.observeFailedPolicy,
		ObserveRetry:   func() { x.observe("recovery", "retry_scheduled", nil) },
	}, recovery.Binding{Session: x.id}).Run(ctx)
}

// A verified first assertion with unavailable readiness or an enrollment
// receipt awaiting a verified risk receipt has no authorizer refresh record
// yet. Reuse the existing bounded backoff for a fresh assertion,
// capped at the normal cadence: one minute, five minutes, then ten minutes.
// A known decision or an existing refresh record restores the normal cadence.
// Only the serialized session worker reads or writes this retry state.
func (x *Session) nextAssertionDelay() time.Duration {
	return x.authorizationIdentity().NextAssertionDelay()
}
