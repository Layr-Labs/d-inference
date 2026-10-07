package payouts

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
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
		unavailable := err != nil || acct == nil || !acct.PayoutsEnabled
		gone := billing.IsDefinitiveAPIErr(err) && billing.IsAccountGoneErr(err)
		if row.Status == "queued" && gone {
			// Reject while still unsent. A failed durable write leaves the
			// generation queued, so recovery never invents a previous send.
			if err := repo.RejectQueuedStripeWithdrawal(row.ID, row.TransferAttempt, time.Now(), "queued_destination_removed"); err != nil {
				s.logger.Error("queued stripe withdrawal rejection persistence failed", "withdrawal_id", row.ID, "error", err)
				s.deferStripeWithdrawal(repo, &row)
				continue
			}
			s.refundConfirmedStripeTransfer(row.ID)
			continue
		}
		if row.Status == "queued" && unavailable {
			s.logger.Warn("queued stripe withdrawal account unavailable", "withdrawal_id", row.ID, "error", err)
			s.deferStripeWithdrawal(repo, &row)
			continue
		}
		if row.Status == "queued" && acct != nil && acct.PayoutInterval == "manual" {
			if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(row.StripeAccountID, acct.Country); err != nil {
				s.logger.Warn("queued stripe withdrawal schedule repair pending", "withdrawal_id", row.ID, "error", err)
				s.deferStripeWithdrawal(repo, &row)
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

func (s *Owner) deferStripeWithdrawal(repo store.StripeWithdrawalQueueStore, wd *store.StripeWithdrawal) {
	if err := repo.DeferStripeWithdrawal(wd.ID, wd.TransferAttempt, time.Now()); err != nil {
		s.logger.Error("queued stripe withdrawal deferral failed", "withdrawal_id", wd.ID, "error", err)
	}
}
