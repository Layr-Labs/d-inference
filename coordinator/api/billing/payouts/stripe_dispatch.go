package payouts

import (
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
)

type stripeDispatchResult struct {
	status int
	body   any
}

func stripeTransferKey(w *store.StripeWithdrawal) string {
	key := "wd-tr-" + w.ID
	if w.TransferAttempt > 0 {
		key += fmt.Sprintf("-funding-%d", w.TransferAttempt)
	}
	return key
}

func (s *Owner) dispatchStripeWithdrawal(wd *store.StripeWithdrawal, country string) stripeDispatchResult {
	withdrawalID, method := wd.ID, wd.Method
	grossMicroUSD, feeMicroUSD, netMicroUSD := wd.AmountMicroUSD, wd.FeeMicroUSD, wd.NetMicroUSD
	netCents := microUSDToCents(netMicroUSD)

	// Step 2: transfer USD from platform balance to the connected account.
	// Retried through retryAmbiguousStripe: the idempotency key makes a
	// replay after a transport blip return the original transfer instead of
	// creating a second one.
	transfer, err := retryAmbiguousStripe(func() (*billing.Transfer, error) {
		return s.billing.StripeConnect().CreateTransfer(billing.CreateTransferParams{
			DestinationAccountID: wd.StripeAccountID,
			AmountCents:          netCents,
			IdempotencyKey:       stripeTransferKey(wd),
			Description:          "Darkbloom credit withdrawal",
		})
	})
	if err != nil && wd.TransferDispatchAttempts > 1 {
		err = fmt.Errorf("prior queued transfer attempt unconfirmed; latest response: %v", err)
	}
	if err != nil && !billing.IsDefinitiveAPIErr(err) {
		// AMBIGUOUS outcome: Stripe never answered, so the idempotent
		// request may have been accepted with the response lost. If it was,
		// the daily sweep will still deliver the money — refunding here
		// would pay the user twice. Park the row in "pending" (no refund):
		// if the transfer landed, ops sees the stuck-pending reconciler
		// alert and completes the row from the Stripe dashboard via the
		// idempotency key; if it didn't, the same alert drives the refund.
		wd.FailureReason = "transfer_create_unconfirmed: " + err.Error()
		if uerr := s.persistWithdrawalUpdate(wd, "ambiguous transfer"); uerr != nil {
			s.logger.Error("stripe payout: persist ambiguous-transfer state failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: transfer outcome UNCONFIRMED — no refund issued, verify against Stripe dashboard",
			"error", err, "withdrawal_id", withdrawalID, "idempotency_key", stripeTransferKey(wd))
		return stripeDispatchResult{http.StatusBadGateway, httpx.ErrorResponse("stripe_error",
			"we couldn't confirm the transfer with Stripe — your withdrawal is on hold and nothing was refunded; it will complete or be resolved automatically, contact support if it doesn't update within 24 hours")}
	}
	if billing.IsInsufficientStripeBalance(err) {
		repo, ok := store.As[store.StripeWithdrawalQueueStore](s.billing.Store())
		if ok {
			if qerr := repo.QueueStripeWithdrawal(wd.ID, wd.TransferAttempt); qerr == nil {
				return stripeDispatchResult{http.StatusAccepted, map[string]any{
					"status": "queued", "withdrawal_id": wd.ID, "amount_usd": formatUSD(grossMicroUSD),
					"fee_usd": formatUSD(feeMicroUSD), "net_usd": formatUSD(netMicroUSD), "method": method,
					"message":           "Your withdrawal is queued until payout funding is available. Your earnings are reserved; no need to submit it again.",
					"balance_micro_usd": s.billing.Ledger().Balance(wd.AccountID),
				}}
			} else {
				s.logger.Error("stripe withdrawal queue persistence failed", "withdrawal_id", wd.ID, "error", qerr)
			}
		}
		// Preserve the proven rejection for manual recovery if the queue write
		// failed. Do not claim an automatic funding retry was scheduled.
		wd.FailureReason = "funding_queue_persistence_failed: " + err.Error()
		_ = s.persistWithdrawalUpdate(wd, "funding queue failure")
		return stripeDispatchResult{http.StatusAccepted, map[string]any{"status": "pending", "withdrawal_id": wd.ID, "method": method, "message": "Your withdrawal is awaiting confirmation. Check Recent withdrawals before submitting again."}}
	}
	if err != nil {
		refunded := s.refundRejectedStripeTransfer(wd, err.Error())
		s.logger.Error("stripe payout: transfer failed", "error", err, "withdrawal_id", withdrawalID)
		refundNote := "your balance was refunded"
		if !refunded {
			refundNote = "the refund to your balance is pending — contact support if it doesn't appear shortly"
		}

		// Classify permanent account problems (races with the pre-check) so
		// the user gets an actionable error instead of a raw Stripe message.
		switch {
		case billing.IsAccountGoneErr(err):
			if perr := s.billing.Store().SetUserStripeAccount(wd.AccountID, "", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: unlink gone account failed", "error", perr)
			}
			return stripeDispatchResult{http.StatusConflict, httpx.ErrorResponse("stripe_account_gone",
				"your Stripe payout account no longer exists — "+refundNote+"; set up payouts again from the billing page")}
		case billing.IsServiceAgreementErr(err):
			if perr := s.billing.Store().SetUserStripeAccount(wd.AccountID, wd.StripeAccountID,
				stripeStatusRestricted, "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: persist restricted status failed", "error", perr)
			}
			return stripeDispatchResult{http.StatusConflict, httpx.ErrorResponse("stripe_account_recreate_required",
				"your payout account can't receive transfers in your country — "+refundNote+"; re-run payout setup from the billing page to recreate it")}
		default:
			return stripeDispatchResult{http.StatusBadGateway, httpx.ErrorResponse("stripe_error",
				"failed to transfer funds ("+refundNote+"): "+err.Error())}
		}
	}
	wd.TransferID = transfer.ID
	wd.Status = "transferred"
	if err := s.persistWithdrawalUpdate(wd, "transfer_id"); err != nil {
		// Transfer succeeded but we lost track of it: the row is stuck
		// "pending" with no transfer_id, invisible to the webhook matcher and
		// sweep reconciler. Money is in the connected account and the daily
		// auto-payout still delivers it — don't refund (double-credit). The
		// reconciler's stale-pending alert surfaces the row for ops.
		s.logger.Error("stripe payout: persist transfer_id failed after retries — row stuck pending, funds deliver via sweep",
			"error", err, "withdrawal_id", withdrawalID, "transfer_id", transfer.ID)
	}

	// Step 3 (standard): nothing to do. The connected account is on Stripe's
	// automatic daily payout schedule, which sweeps the balance to the user's
	// bank in their local currency. We deliberately do NOT create a manual
	// payout here: manual payouts require the balance to already be available
	// (transfers to `recipient` accounts take +24h) and must be denominated in
	// the connected account's settlement currency — Stripe converts cross-
	// border transfers, so a hardcoded USD payout fails for any non-USD
	// account. The sweep handles both; the payout.paid webhook marks the row.
	if method == "standard" {
		s.logger.Info("stripe payout: transferred (auto-payout will deliver)",
			"withdrawal_id", withdrawalID,
			"account", wd.AccountID[:min(8, len(wd.AccountID))]+"...",
			"gross_micro_usd", grossMicroUSD,
			"net_micro_usd", netMicroUSD,
		)
		return stripeDispatchResult{http.StatusOK, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       transfer.ID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"eta":               etaForMethod(method, country),
			"message":           sweepDeliveryMessage(country),
			"balance_micro_usd": s.billing.Ledger().Balance(wd.AccountID),
		}}
	}

	return s.dispatchStripeInstantPayout(wd, country)
}
