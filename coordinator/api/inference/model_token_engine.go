package inference

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func withModelTokenRequest(r *http.Request) *http.Request { return promotions.WithRequest(r) }
func modelTokenReservation(r *http.Request) *store.ModelTokenReservation {
	return promotions.Reservation(r)
}

func (s *Owner) releaseModelTokenRequest(r *http.Request) bool { return s.promotions.ReleaseRequest(r) }
func (s *Owner) settleModelTokenPromotion(pr *registry.PendingRequest, provider *registry.Provider, usage protocol.UsageInfo, rates payments.Rates, feePercent *int64, freeSelf, referralEnabled bool, onSettled func(int64)) (bool, int64, int64, error) {
	return s.promotions.Settle(pr, provider, usage, rates, feePercent, freeSelf, referralEnabled, onSettled)
}
func promotionAdmission(p balanceReservationParams) promotions.Admission {
	return promotions.Admission{Model: p.model, PublicModel: p.publicModel, BillingPromptTokens: p.billingPromptTokens, EstimatedPromptTokens: p.estimatedPromptTokens, RequestedMaxTokens: p.requestedMaxTokens}
}
func (s *Owner) RunModelTokenMaintenance(ctx context.Context) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.consumerCharges.Run(ctx, s.logger)
	}()
	s.promotions.Run(ctx)
	<-done
}
