package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) send(ctx context.Context, action string) bool {
	enrollments, _ := store.As[store.AppAttestEnrollmentStore](x.s.store)
	r := exchange.Send(ctx, exchange.SendDependencies{Enrollments: enrollments, Scope: x.storageAdmission(), Integrity: &x.integrity,
		Transport: x.provider.EnqueueText}, x.issuedChallenge().Binding, x.key, action)
	if r.Challenge != "" {
		x.challenge, x.expected = r.Challenge, r.Expected
	}
	if !r.Started.IsZero() {
		x.started = r.Started
	}
	x.observe(action, r.Outcome, nil)
	return r.Sent
}
