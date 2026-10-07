package payouts

import "github.com/eigeninference/d-inference/coordinator/store"

// Preserve a definitive rejection before refunding. Recovery can repeat the
// atomic credit and flag update without resending a rejected transfer.
func (s *Owner) refundRejectedStripeTransfer(wd *store.StripeWithdrawal, reason string) bool {
	repo, ok := store.As[store.StripeSettlementStore](s.billing.Store())
	if !ok {
		return false
	}
	if err := repo.RecordStripeTransferRejection(wd.ID, reason); err != nil {
		s.logger.Error("stripe payout: persist rejection failed; manual reconciliation required", "withdrawal_id", wd.ID, "error", err)
		return false
	}
	return s.refundConfirmedStripeTransfer(wd.ID)
}

func (s *Owner) refundConfirmedStripeTransfer(withdrawalID string) bool {
	repo, ok := store.As[store.StripeSettlementStore](s.billing.Store())
	if !ok {
		return false
	}
	_, err := repo.RefundRejectedStripeWithdrawal(withdrawalID)
	if err != nil {
		s.logger.Error("stripe payout: refund pending recovery", "withdrawal_id", withdrawalID, "error", err)
	}
	return err == nil
}
