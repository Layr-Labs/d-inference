package recovery

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"
)

// Binding identifies one fresh exchange. An attempt must reload durable key
// acceptance when this binding changes; a retry never reuses a nonce.
type Binding struct{ Session string }

type Outcome struct {
	Reason      string
	AssertionAt time.Time
}

// FailurePolicyOutcome distinguishes operational uncertainty from a known
// rejection; it does not itself grant or revoke serving permission.
func FailurePolicyOutcome(reason string) string {
	if RetryableOutcome(reason) || reason == "unsupported" || reason == "not_configured" || reason == "" {
		return "unknown"
	}
	return "ineligible"
}

type DriverDependencies struct {
	Attempt          func(context.Context, Binding) Outcome
	Rebind           func(Binding)
	Wait             func(context.Context, time.Duration) bool
	BackoffRemaining func(context.Context, time.Time) time.Duration
	RotationDue      func(Outcome) bool
	EnrollmentDue    func(Outcome) bool
	ObserveFailure   func(string)
	ObserveRetry     func()
}

// Driver owns the retry generation and failure count, not the cryptographic
// exchange. Its collaborators perform the actual archive, policy and IO work.
type Driver struct {
	deps        DriverDependencies
	binding     Binding
	failures    int
	assertionAt time.Time
}

func NewDriver(deps DriverDependencies, binding Binding) *Driver {
	if deps.Wait == nil {
		deps.Wait = Wait
	}
	return &Driver{deps: deps, binding: binding}
}

func (d *Driver) Run(ctx context.Context) {
	if d.deps.BackoffRemaining != nil {
		if delay := d.deps.BackoffRemaining(ctx, time.Now().UTC()); delay > 0 && !d.deps.Wait(ctx, delay) {
			return
		}
	}
	for ; ctx.Err() == nil; d.failures++ {
		outcome := d.deps.Attempt(ctx, d.binding)
		if ctx.Err() != nil {
			return
		}
		if d.deps.ObserveFailure != nil {
			d.deps.ObserveFailure(outcome.Reason)
		}
		if !RetryableOutcome(outcome.Reason) {
			return
		}
		if outcome.AssertionAt.After(d.assertionAt) {
			d.failures = 0
		}
		d.assertionAt = outcome.AssertionAt
		delay := ExchangeRetryDelay(outcome.Reason, d.failures)
		switch {
		case d.deps.RotationDue != nil && d.deps.RotationDue(outcome):
			delay = RotationRetryDelay()
		case d.deps.EnrollmentDue != nil && d.deps.EnrollmentDue(outcome):
			delay = EnrollmentInvalidKeyBackoff
		}
		if d.deps.ObserveRetry != nil {
			d.deps.ObserveRetry()
		}
		if !d.deps.Wait(ctx, delay) {
			return
		}
		var nonce [32]byte
		if _, err := rand.Read(nonce[:]); err != nil {
			return
		}
		d.binding = Binding{Session: base64.StdEncoding.EncodeToString(nonce[:])}
		if d.deps.Rebind != nil {
			d.deps.Rebind(d.binding)
		}
	}
}
