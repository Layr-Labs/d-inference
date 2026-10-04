package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func reservationParams(p balanceReservationParams) reservations.Params {
	return reservations.Params{Model: p.model, PublicModel: p.publicModel, BillingPromptTokens: p.billingPromptTokens, EstimatedPromptTokens: p.estimatedPromptTokens, RequestedMaxTokens: p.requestedMaxTokens, Stream: p.stream, RequiresVision: p.requiresVision, HasTools: p.hasTools, SelfRoute: p.policy.enabled}
}

func (s *Owner) reserveInitialBalance(accountID, model string, amount int64) (bool, error) {
	return s.reservations.ReserveInitial(accountID, model, amount)
}
func (s *Owner) releaseInitialReservation(accountID, model string, amount int64, serviceMode bool) {
	s.reservations.ReleaseInitial(accountID, model, amount, serviceMode)
}
func (s *Owner) releaseServiceReservation(pr *registry.PendingRequest, reason string) {
	s.reservations.ReleaseService(pr, reason)
}

func (s *Owner) recordBalanceRejection(r *http.Request, parsed map[string]any, p reservations.Params, reason string) {
	s.recordRejection(rejectionInfo{
		r: r, stage: "balance", reasonCode: reason, httpStatus: http.StatusPaymentRequired,
		keyID: access.KeyIDFromContext(r.Context()), consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
		requestedModel: p.PublicModel, resolvedModel: p.Model, stream: p.Stream,
		estimatedPromptTokens: p.EstimatedPromptTokens, requestedMaxTokens: p.RequestedMaxTokens,
		requiresVision: p.RequiresVision, hasTools: p.HasTools, params: rejectionSamplingParams(parsed),
	})
}
