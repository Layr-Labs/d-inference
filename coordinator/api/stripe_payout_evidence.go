package api

import (
	"errors"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) reconcileProvenPayout(pe *billing.PayoutEvent) error {
	transfers, err := s.billing.StripeConnect().PayoutTransfers(pe.ConnectedAcct, pe.ID)
	if err != nil {
		return err
	}
	// Look up by evidence IDs rather than paging unrelated historical rows.
	for transfer := range transfers {
		wd, err := s.billing.Store().GetStripeWithdrawalByTransferID(transfer)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return err
		}
		if wd.StripeAccountID != pe.ConnectedAcct || wd.Status != "transferred" || wd.Refunded || wd.PayoutID != "" {
			continue
		}
		if _, err := s.billing.Store().MarkStripeWithdrawalPaid(wd.ID, "", pe.ID); err != nil {
			return err
		}
	}
	return nil
}
