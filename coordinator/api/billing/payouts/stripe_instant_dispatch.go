package payouts

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) dispatchStripeInstantPayout(wd *store.StripeWithdrawal, country string) stripeDispatchResult {
	withdrawalID, method := wd.ID, wd.Method
	grossMicroUSD, feeMicroUSD, netMicroUSD := wd.AmountMicroUSD, wd.FeeMicroUSD, wd.NetMicroUSD
	netCents := microUSDToCents(netMicroUSD)

	// Step 3 (instant): create the Stripe Instant Payout from the connected
	// account to the user's debit card. Instant payouts are USD/debit-card
	// only, which the InstantEligible gate above guarantees. Idempotent —
	// ambiguous transport failures are retried with the same key.
	payout, err := retryAmbiguousStripe(func() (*billing.Payout, error) {
		return s.billing.StripeConnect().CreatePayout(billing.CreatePayoutParams{
			OnBehalfOfAccountID: wd.StripeAccountID,
			AmountCents:         netCents,
			Method:              method,
			IdempotencyKey:      "wd-po-" + withdrawalID,
			Description:         "Darkbloom credit withdrawal",
		})
	})
	if err != nil && !billing.IsDefinitiveAPIErr(err) {
		// AMBIGUOUS outcome: the payout may exist with its ID lost in
		// flight. If it does, the user IS getting instant delivery — so do
		// NOT refund the instant fee, and don't guess a terminal state. The
		// row keeps its transfer and no payout ID; if the payout landed,
		// its paid webhook won't match (unmatched non-automatic payouts are
		// ignored) and no sweep will fire on the emptied balance, so the
		// 48h reconciler alert surfaces the row for ops to settle via the
		// idempotency key. If it didn't land, the daily sweep delivers and
		// completes the row; ops refunds the fee from the same alert trail.
		wd.FailureReason = "instant_payout_unconfirmed: " + err.Error()
		if uerr := s.persistWithdrawalUpdate(wd, "ambiguous payout"); uerr != nil {
			s.logger.Error("stripe payout: persist ambiguous-payout state failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: instant payout outcome UNCONFIRMED — fee NOT refunded, verify against Stripe dashboard",
			"error", err, "withdrawal_id", withdrawalID, "transfer_id", wd.TransferID,
			"idempotency_key", "wd-po-"+withdrawalID)
		return stripeDispatchResult{http.StatusAccepted, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       wd.TransferID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"message":           "we couldn't confirm your instant payout with Stripe — if it went through, funds reach your card in ~30 minutes; otherwise the daily payout delivers them and support will refund the instant fee, contact support if nothing arrives within 24 hours",
			"balance_micro_usd": s.billing.Ledger().Balance(wd.AccountID),
		}}
	}
	if err != nil {
		// Transfer succeeded — funds are in the connected account and the
		// daily auto-payout will deliver them via the standard rail. We do
		// NOT refund the principal (that would double-credit), but we DO
		// refund the instant fee: the user isn't getting instant delivery.
		wd.FailureReason = "instant_payout_create_failed: " + err.Error()
		// Reference-idempotent: shares its ledger ref with the webhook
		// fee-refund path, so no interleaving pays the fee twice — a later
		// transfer.reversed re-checks the same reference.
		feeRefunded := feeMicroUSD == 0
		if feeMicroUSD > 0 &&
			s.creditRefundOnceWithRetry(wd.AccountID, feeMicroUSD, "stripe_withdraw_fee:"+withdrawalID, withdrawalID) {
			feeRefunded = true
			wd.FeeRefunded = true
			wd.FailureReason += " (instant fee refunded)"
		}
		if uerr := s.persistWithdrawalUpdate(wd, "payout failure"); uerr != nil {
			s.logger.Error("stripe payout: persist payout failure failed",
				"error", uerr, "withdrawal_id", withdrawalID)
		}
		s.logger.Error("stripe payout: create instant payout failed", "error", err,
			"withdrawal_id", withdrawalID, "transfer_id", wd.TransferID)
		msg := "instant payout unavailable — the fee was refunded and funds will arrive via the standard daily payout"
		if !feeRefunded {
			msg = "instant payout unavailable — funds will arrive via the standard daily payout; the instant-fee refund is pending, contact support if it doesn't appear shortly"
		}
		return stripeDispatchResult{http.StatusAccepted, map[string]any{
			"status":            "transferred",
			"withdrawal_id":     withdrawalID,
			"transfer_id":       wd.TransferID,
			"amount_usd":        formatUSD(grossMicroUSD),
			"fee_usd":           formatUSD(feeMicroUSD),
			"net_usd":           formatUSD(netMicroUSD),
			"method":            method,
			"message":           msg,
			"balance_micro_usd": s.billing.Ledger().Balance(wd.AccountID),
		}}
	}
	wd.PayoutID = payout.ID
	if err := s.persistWithdrawalUpdate(wd, "payout_id"); err != nil {
		// Payout succeeded but we couldn't persist the ID. Webhook will
		// arrive with the payout ID — without the index entry the sweep
		// matcher will still reconcile it by connected account. Log loudly
		// so ops can double-check via the Stripe dashboard.
		s.logger.Error("stripe payout: persist payout_id failed after retries",
			"error", err, "withdrawal_id", withdrawalID,
			"transfer_id", wd.TransferID, "payout_id", payout.ID)
	}

	s.logger.Info("stripe payout: created",
		"withdrawal_id", withdrawalID,
		"account", wd.AccountID[:min(8, len(wd.AccountID))]+"...",
		"method", method,
		"gross_micro_usd", grossMicroUSD,
		"fee_micro_usd", feeMicroUSD,
		"net_micro_usd", netMicroUSD,
	)
	return stripeDispatchResult{http.StatusOK, map[string]any{
		"status":            "submitted",
		"withdrawal_id":     withdrawalID,
		"transfer_id":       wd.TransferID,
		"payout_id":         payout.ID,
		"amount_usd":        formatUSD(grossMicroUSD),
		"fee_usd":           formatUSD(feeMicroUSD),
		"net_usd":           formatUSD(netMicroUSD),
		"method":            method,
		"eta":               etaForMethod(method, country),
		"arrival_unix":      payout.ArrivalDate,
		"balance_micro_usd": s.billing.Ledger().Balance(wd.AccountID),
	}}
}
