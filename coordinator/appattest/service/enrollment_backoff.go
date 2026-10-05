package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) enrollmentBackoff() *recovery.Enrollment {
	return recovery.NewEnrollment(recovery.EnrollmentDependencies{
		Store: func() store.AppAttestKeyRotationStore {
			st, _ := store.As[store.AppAttestKeyRotationStore](x.s.store)
			return st
		},
		Account: x.account, CanonicalMachine: x.canonicalMachine,
		Acquire: x.acquireStorage, AcquireWithin: x.acquireStorageWithin,
		Count:   func(phase string) { x.s.ddIncr("app_attest.enrollment_backoff", []string{"phase:" + phase}) },
		Observe: func(outcome string) { x.observeSideEffect("recovery", outcome) },
	})
}

func (x *Session) enrollmentBackoffDue(failure string) bool {
	return x.enrollmentBackoff().Due(failure, x.expected)
}

func (x *Session) enrollmentBackoffRemaining(ctx context.Context, now time.Time) time.Duration {
	return x.enrollmentBackoff().Remaining(ctx, now)
}
