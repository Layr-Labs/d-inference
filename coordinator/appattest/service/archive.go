package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/input"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) pipeline() *exchange.Pipeline {
	if x.archive == nil {
		x.archive, _ = store.As[store.AppAttestArchiveStore](x.store)
	}
	enrollments, _ := store.As[store.AppAttestEnrollmentStore](x.s.store)
	return exchange.NewPipeline(exchange.PipelineDependencies{
		Verification: x.verificationDependencies(), Archive: x.archive, Enrollments: enrollments, Provider: x.provider,
		Budget: x.s.shadowStorageBudget(), Scope: x.storageAdmission(), Integrity: &x.integrity, Authorization: x.s.authorizer,
		Count: x.s.ddIncr,
		Transition: func(result exchange.Result, reply protocol.AppAttestShadowPayload) string {
			x.applyExchangeResult(result, reply)
			return x.lastOutcome
		},
	})
}

func (x *Session) pendingAttempt() exchange.Attempt {
	return exchange.Attempt{Challenge: x.issuedChallenge(), ReadyContext: x.readyDiagnostics,
		Rejection: x.rejectReason, PreviousOutcome: x.lastOutcome}
}

func (x *Session) handle(ctx context.Context, reply protocol.AppAttestShadowPayload) string {
	result := x.pipeline().Handle(ctx, x.pendingAttempt(), reply)
	x.lastOutcome = result.Outcome
	return result.Next
}

func (x *Session) closeAndArchivePending() {
	x.admission.Close()
	x.rejectReason = "session_stopped"
	input.DrainStopped(x.in, func(ctx context.Context, reply protocol.AppAttestShadowPayload) { x.handle(ctx, reply) })
}
