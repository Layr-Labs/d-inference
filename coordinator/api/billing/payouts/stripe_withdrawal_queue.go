package payouts

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (s *Owner) ProcessStripeWithdrawalQueue(ctx context.Context) {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		return
	}
	repo, ok := store.As[store.StripeWithdrawalQueueStore](s.billing.Store())
	if !ok {
		return
	}
	rows, err := repo.ListStripeWithdrawalQueue(time.Now(), 200)
	if err != nil {
		s.logger.Error("stripe withdrawal queue scan failed", "error", err)
		return
	}
	for _, row := range rows {
		if ctx.Err() != nil {
			return
		}
		// Revalidate the saved destination without substituting a new account.
		acct, err := s.billing.StripeConnect().GetAccount(row.StripeAccountID)
		unavailable := err != nil || !acct.PayoutsEnabled
		gone := billing.IsDefinitiveAPIErr(err) && billing.IsAccountGoneErr(err)
		if row.Status == "queued" && unavailable && !gone {
			s.logger.Warn("queued stripe withdrawal account unavailable", "withdrawal_id", row.ID, "error", err)
			continue
		}
		if row.Status == "queued" && acct != nil && acct.PayoutInterval == "manual" {
			if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(row.StripeAccountID, acct.Country); err != nil {
				s.logger.Warn("queued stripe withdrawal schedule repair pending", "withdrawal_id", row.ID, "error", err)
				continue
			}
		}
		wd, err := repo.ClaimStripeWithdrawal(row.ID, time.Now())
		if err != nil {
			s.logger.Error("stripe withdrawal queue claim failed", "withdrawal_id", row.ID, "error", err)
			continue
		}
		if wd == nil {
			continue
		}
		// Only a fresh unsent queue claim can refund a removed destination.
		// A previous ambiguous send must be retried with its original key.
		if gone && wd.TransferDispatchAttempts == 1 {
			s.refundRejectedStripeTransfer(wd, "queued_destination_removed")
			continue
		}
		country := ""
		if acct != nil {
			country = acct.Country
		}
		result := s.dispatchStripeWithdrawal(wd, country)
		if result.status >= 400 {
			s.logger.Warn("queued stripe withdrawal dispatch failed", "withdrawal_id", wd.ID, "status", result.status)
		}
	}
}
