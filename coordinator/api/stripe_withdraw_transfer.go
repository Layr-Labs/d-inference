package api

import (
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type stripeTransferRequest struct {
	User            *store.User
	GrossMicroUSD   int64
	FeeMicroUSD     int64
	Method          string
	Source          string
	WithdrawalID    string
	ScheduledFor    *time.Time
	RetryCutoff     time.Time
	TransferMessage string
}

type stripeTransferResult struct {
	Withdrawal        *store.StripeWithdrawal
	Transfer          *billing.Transfer
	TransferPersisted bool
}

// stripeTransferError carries stable API copy while preserving the underlying
// error for worker retry/authorization decisions.
type stripeTransferError struct {
	StatusCode int
	Code       string
	Message    string
	Err        error
	Withdrawal *store.StripeWithdrawal
}

func (e *stripeTransferError) Error() string {
	if e.Err != nil {
		return e.Err.Error()
	}
	return e.Message
}

func (e *stripeTransferError) Unwrap() error { return e.Err }

func writeStripeTransferError(w http.ResponseWriter, payoutErr *stripeTransferError) {
	writeJSON(w, payoutErr.StatusCode, errorResponse(payoutErr.Code, payoutErr.Message))
}

// validateStripePayoutAccount refreshes every condition that can make a
// transfer fail before a new ledger debit is created.
func (s *Server) validateStripePayoutAccount(user *store.User, method string) (*billing.ExpressAccount, *stripeTransferError) {
	acct, err := s.billing.StripeConnect().GetAccount(user.StripeAccountID)
	if err != nil {
		if billing.IsAccountGoneErr(err) {
			s.logger.Warn("stripe payout: stored account gone — unlinking",
				"stripe_account_id", user.StripeAccountID, "error", err)
			if perr := s.setStripeAccountIfCurrent(user.AccountID, user.StripeAccountID,
				"", "", "", "", "", false); perr != nil {
				s.logger.Error("stripe payout: unlink gone account failed", "error", perr)
			}
			return nil, &stripeTransferError{
				StatusCode: http.StatusConflict,
				Code:       "stripe_account_gone",
				Message:    "your Stripe payout account no longer exists — set up payouts again from the billing page",
				Err:        err,
			}
		}
		s.logger.Error("stripe payout: account pre-check failed", "error", err)
		return nil, &stripeTransferError{
			StatusCode: http.StatusBadGateway,
			Code:       "stripe_error",
			Message:    "could not verify your payout account with Stripe — try again shortly",
			Err:        err,
		}
	}

	requiredAgreement := billing.RequiredServiceAgreement(
		s.billing.StripeConnect().PlatformCountry(), acct.Country)
	if billing.NormalizeServiceAgreement(acct.ServiceAgreement) != requiredAgreement {
		if perr := s.setStripeAccountIfCurrent(user.AccountID, user.StripeAccountID,
			user.StripeAccountID, stripeStatusRestricted, acct.Country,
			acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); perr != nil {
			s.logger.Error("stripe payout: persist restricted status failed", "error", perr)
		}
		s.logger.Warn("stripe payout: service agreement mismatch — user must re-onboard",
			"stripe_account_id", user.StripeAccountID, "country", acct.Country,
			"have", billing.NormalizeServiceAgreement(acct.ServiceAgreement), "want", requiredAgreement)
		return nil, &stripeTransferError{
			StatusCode: http.StatusConflict,
			Code:       "stripe_account_recreate_required",
			Message:    "your payout account can't receive transfers in your country — re-run payout setup from the billing page to recreate it",
		}
	}
	if !acct.PayoutsEnabled {
		if perr := s.setStripeAccountIfCurrent(user.AccountID, user.StripeAccountID,
			user.StripeAccountID, stripeStatusForAccount(acct), acct.Country,
			acct.DestinationType, acct.DestinationLast4, acct.InstantEligible); perr != nil {
			s.logger.Error("stripe payout: persist disabled status failed", "error", perr)
		}
		return nil, &stripeTransferError{
			StatusCode: http.StatusForbidden,
			Code:       "not_onboarded",
			Message:    "your Stripe account can't receive payouts yet — finish onboarding from the billing page",
		}
	}
	if acct.PayoutInterval == "manual" {
		if err := s.billing.StripeConnect().UpdateAccountPayoutScheduleAuto(user.StripeAccountID, acct.Country); err != nil {
			s.logger.Error("stripe payout: payout schedule self-heal failed — refusing withdrawal",
				"stripe_account_id", user.StripeAccountID, "error", err)
			return nil, &stripeTransferError{
				StatusCode: http.StatusBadGateway,
				Code:       "stripe_error",
				Message:    "could not enable automatic payouts on your account — try again shortly",
				Err:        err,
			}
		}
		s.logger.Info("stripe payout: payout schedule healed to automatic",
			"stripe_account_id", user.StripeAccountID)
	}
	if method == "instant" && !acct.InstantEligible && !user.StripeInstantEligible {
		return nil, &stripeTransferError{
			StatusCode: http.StatusBadRequest,
			Code:       "instant_unavailable",
			Message:    "instant payouts require a debit card destination — link one in Stripe to enable",
		}
	}
	return acct, nil
}

// setStripeAccountIfCurrent prevents a resumed automatic withdrawal for an old
// destination from clearing or restricting a newly linked account.
func (s *Server) setStripeAccountIfCurrent(
	accountID, expectedStripeAccountID, stripeAccountID, status, country,
	destinationType, destinationLast4 string, instantEligible bool,
) error {
	_, err := s.billing.Store().SetUserStripeAccountIfCurrent(
		accountID, expectedStripeAccountID, stripeAccountID, status, country,
		destinationType, destinationLast4, instantEligible,
	)
	return err
}

// executeStripeTransfer persists the debit before making an idempotent Stripe
// transfer. Automatic requests can safely resume the same deterministic
// withdrawal after a crash or on another coordinator instance.
func (s *Server) executeStripeTransfer(req stripeTransferRequest) (*stripeTransferResult, *stripeTransferError) {
	if req.Source == "" {
		req.Source = store.StripeWithdrawalSourceManual
	}
	if req.Source == store.StripeWithdrawalSourceAutomatic {
		acquired, release, err := s.billing.Store().TryLockStripeWithdrawal(req.WithdrawalID)
		if err != nil {
			return nil, &stripeTransferError{
				StatusCode: http.StatusServiceUnavailable,
				Code:       "auto_withdraw_lock_failed",
				Message:    "automatic withdrawal could not acquire its execution lock",
				Err:        err,
			}
		}
		if !acquired {
			return nil, &stripeTransferError{
				StatusCode: http.StatusConflict,
				Code:       "auto_withdraw_busy",
				Message:    "automatic withdrawal is already being processed",
				Err:        store.ErrStripeWithdrawalBusy,
			}
		}
		defer release()
		if existing := s.loadAutomaticWithdrawal(req, 1); existing != nil {
			return s.continueAutomaticStripeTransfer(existing, req.TransferMessage, req.RetryCutoff)
		}
	}

	netMicroUSD := req.GrossMicroUSD - req.FeeMicroUSD
	wd := &store.StripeWithdrawal{
		ID:              req.WithdrawalID,
		AccountID:       req.User.AccountID,
		StripeAccountID: req.User.StripeAccountID,
		AmountMicroUSD:  req.GrossMicroUSD,
		FeeMicroUSD:     req.FeeMicroUSD,
		NetMicroUSD:     netMicroUSD,
		Method:          req.Method,
		Source:          req.Source,
		ScheduledFor:    req.ScheduledFor,
		Status:          "pending",
	}
	debitRef := "stripe_withdraw:" + req.WithdrawalID

	var err error
	if req.Source == store.StripeWithdrawalSourceAutomatic {
		if req.ScheduledFor == nil {
			return nil, &stripeTransferError{
				StatusCode: http.StatusInternalServerError,
				Code:       "internal_error",
				Message:    "automatic withdrawal schedule is missing",
				Err:        errors.New("automatic withdrawal schedule is missing"),
			}
		}
		err = s.billing.Store().CreateStripeAutoWithdrawalWithDebit(
			wd, store.LedgerStripePayout, debitRef, *req.ScheduledFor,
		)
	} else {
		err = s.billing.Store().CreateStripeWithdrawalWithDebit(
			wd, store.LedgerStripePayout, debitRef,
		)
	}
	if err != nil {
		// Another coordinator may have committed the deterministic row between
		// our first lookup and insert. Load it and continue the same transfer.
		if req.Source == store.StripeWithdrawalSourceAutomatic {
			if existing := s.loadAutomaticWithdrawal(req, 3); existing != nil {
				return s.continueAutomaticStripeTransfer(existing, req.TransferMessage, req.RetryCutoff)
			}
		}
		if errors.Is(err, store.ErrInsufficientBalance) {
			return nil, &stripeTransferError{
				StatusCode: http.StatusBadRequest,
				Code:       "insufficient_withdrawable",
				Message:    "insufficient withdrawable balance — only earned funds can be withdrawn",
				Err:        err,
			}
		}
		if errors.Is(err, store.ErrAutoWithdrawNotAuthorized) {
			return nil, &stripeTransferError{
				StatusCode: http.StatusConflict,
				Code:       "auto_withdraw_not_authorized",
				Message:    "automatic withdrawal authorization changed before the payout started",
				Err:        err,
			}
		}
		s.logger.Error("stripe payout: debit+persist withdrawal failed",
			"error", err, "withdrawal_id", req.WithdrawalID)
		return nil, &stripeTransferError{
			StatusCode: http.StatusInternalServerError,
			Code:       "internal_error",
			Message:    "could not start the withdrawal — nothing was debited; try again shortly",
			Err:        err,
		}
	}

	return s.continueStripeTransfer(wd, req.TransferMessage)
}

func (s *Server) continueAutomaticStripeTransfer(wd *store.StripeWithdrawal, description string, retryCutoff time.Time) (*stripeTransferResult, *stripeTransferError) {
	if retryCutoff.IsZero() {
		retryCutoff = time.Now().Add(-stripeAutoWithdrawResumeWindow)
	}
	if wd.Status == "pending" && !wd.CreatedAt.After(retryCutoff) {
		return nil, &stripeTransferError{
			StatusCode: http.StatusConflict,
			Code:       "auto_withdraw_reconciliation_required",
			Message:    "automatic withdrawal is outside Stripe's safe retry window",
			Err:        store.ErrStripeWithdrawalReconciliationRequired,
			Withdrawal: wd,
		}
	}
	return s.continueStripeTransfer(wd, description)
}

func (s *Server) loadAutomaticWithdrawal(req stripeTransferRequest, attempts int) *store.StripeWithdrawal {
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			time.Sleep(25 * time.Millisecond)
		}
		wd, err := s.billing.Store().GetStripeWithdrawal(req.WithdrawalID)
		if err != nil {
			continue
		}
		if wd.Source != store.StripeWithdrawalSourceAutomatic ||
			wd.AccountID != req.User.AccountID ||
			wd.StripeAccountID != req.User.StripeAccountID {
			s.logger.Error("stripe auto payout: deterministic withdrawal ID collision",
				"withdrawal_id", req.WithdrawalID)
			return nil
		}
		return wd
	}
	return nil
}

func (s *Server) continueStripeTransfer(wd *store.StripeWithdrawal, description string) (*stripeTransferResult, *stripeTransferError) {
	if wd.Status != "pending" {
		return &stripeTransferResult{Withdrawal: wd}, nil
	}
	if wd.TransferID != "" {
		persisted := s.markStripeWithdrawalTransferredWithRetry(wd.ID, wd.TransferID)
		if !persisted {
			s.logger.Error("stripe payout: recover transferred state failed",
				"withdrawal_id", wd.ID, "transfer_id", wd.TransferID)
		}
		wd.Status = "transferred"
		return &stripeTransferResult{
			Withdrawal:        wd,
			Transfer:          &billing.Transfer{ID: wd.TransferID},
			TransferPersisted: persisted,
		}, nil
	}

	markFailedRefund := func(reason string) bool {
		refunded := s.failStripeWithdrawalAndRefundWithRetry(wd.ID, reason)
		if refunded {
			wd.Refunded = true
			wd.Status = "failed"
			wd.FailureReason = reason
		}
		return refunded
	}

	if description == "" {
		description = "Darkbloom credit withdrawal"
	}
	createTransfer := func() (*billing.Transfer, error) {
		return s.billing.StripeConnect().CreateTransfer(billing.CreateTransferParams{
			DestinationAccountID: wd.StripeAccountID,
			AmountCents:          microUSDToCents(wd.NetMicroUSD),
			IdempotencyKey:       "wd-tr-" + wd.ID,
			Description:          description,
		})
	}
	var transfer *billing.Transfer
	var err error
	if wd.Source == store.StripeWithdrawalSourceAutomatic {
		// The worker retries on its next bounded sweep. One HTTP attempt keeps
		// a Stripe outage from overrunning the worker cadence.
		transfer, err = createTransfer()
	} else {
		transfer, err = retryAmbiguousStripe(createTransfer)
	}
	if err != nil && !billing.IsDefinitiveAPIErr(err) {
		reason := "transfer_create_unconfirmed: " + err.Error()
		wd.FailureReason = reason
		if !s.recordPendingStripeFailureWithRetry(
			wd.ID, reason, time.Now().Add(stripeAutoWithdrawInterval),
		) {
			s.logger.Error("stripe payout: persist ambiguous-transfer state failed",
				"withdrawal_id", wd.ID)
		}
		s.logger.Error("stripe payout: transfer outcome UNCONFIRMED — no refund issued, verify against Stripe dashboard",
			"error", err, "withdrawal_id", wd.ID, "idempotency_key", "wd-tr-"+wd.ID)
		return nil, &stripeTransferError{
			StatusCode: http.StatusBadGateway,
			Code:       "stripe_error",
			Message:    "we couldn't confirm the transfer with Stripe — your withdrawal is on hold and nothing was refunded; it will complete or be resolved automatically, contact support if it doesn't update within 24 hours",
			Err:        err,
			Withdrawal: wd,
		}
	}
	if err != nil {
		refunded := markFailedRefund("transfer_create_failed: " + err.Error())
		s.logger.Error("stripe payout: transfer failed",
			"error", err, "withdrawal_id", wd.ID)
		refundNote := "your balance was refunded"
		if !refunded {
			refundNote = "the refund to your balance is pending — contact support if it doesn't appear shortly"
		}

		payoutErr := &stripeTransferError{
			StatusCode: http.StatusBadGateway,
			Code:       "stripe_error",
			Message:    "failed to transfer funds (" + refundNote + "): " + err.Error(),
			Err:        err,
			Withdrawal: wd,
		}
		switch {
		case billing.IsAccountGoneErr(err):
			if persistErr := s.setStripeAccountIfCurrent(
				wd.AccountID, wd.StripeAccountID, "", "", "", "", "", false,
			); persistErr != nil {
				s.logger.Error("stripe payout: unlink gone account failed", "error", persistErr)
			}
			payoutErr.StatusCode = http.StatusConflict
			payoutErr.Code = "stripe_account_gone"
			payoutErr.Message = "your Stripe payout account no longer exists — " +
				refundNote + "; set up payouts again from the billing page"
		case billing.IsServiceAgreementErr(err):
			if persistErr := s.setStripeAccountIfCurrent(
				wd.AccountID, wd.StripeAccountID, wd.StripeAccountID,
				stripeStatusRestricted, "", "", "", false,
			); persistErr != nil {
				s.logger.Error("stripe payout: persist restricted status failed", "error", persistErr)
			}
			payoutErr.StatusCode = http.StatusConflict
			payoutErr.Code = "stripe_account_recreate_required"
			payoutErr.Message = "your payout account can't receive transfers in your country — " +
				refundNote + "; re-run payout setup from the billing page to recreate it"
		}
		return nil, payoutErr
	}

	wd.TransferID = transfer.ID
	wd.Status = "transferred"
	persisted := s.markStripeWithdrawalTransferredWithRetry(wd.ID, transfer.ID)
	if !persisted {
		s.logger.Error("stripe payout: persist transfer_id failed after retries — row stuck pending, funds deliver via sweep",
			"withdrawal_id", wd.ID, "transfer_id", transfer.ID)
	}
	return &stripeTransferResult{
		Withdrawal: wd, Transfer: transfer, TransferPersisted: persisted,
	}, nil
}

func (s *Server) failStripeWithdrawalAndRefundWithRetry(withdrawalID, reason string) bool {
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		refunded, err := s.billing.Store().FailStripeWithdrawalAndRefund(withdrawalID, reason)
		if err == nil {
			return refunded
		}
		s.logger.Warn("stripe payout: atomic refund attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", withdrawalID)
	}
	s.logger.Error("stripe payout: atomic refund failed after retries — MANUAL REVIEW REQUIRED",
		"withdrawal_id", withdrawalID)
	return false
}

func (s *Server) markStripeWithdrawalTransferredWithRetry(withdrawalID, transferID string) bool {
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		applied, err := s.billing.Store().MarkStripeWithdrawalTransferred(withdrawalID, transferID)
		if err == nil {
			return applied
		}
		s.logger.Warn("stripe payout: transfer transition attempt failed",
			"attempt", attempt+1, "error", err,
			"withdrawal_id", withdrawalID, "transfer_id", transferID)
	}
	return false
}

func (s *Server) recordPendingStripeFailureWithRetry(withdrawalID, reason string, retryAfter time.Time) bool {
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(time.Duration(attempt) * 200 * time.Millisecond)
		}
		applied, err := s.billing.Store().RecordStripeWithdrawalPendingFailure(
			withdrawalID, reason, retryAfter,
		)
		if err == nil {
			return applied
		}
		s.logger.Warn("stripe payout: pending failure persist attempt failed",
			"attempt", attempt+1, "error", err, "withdrawal_id", withdrawalID)
	}
	return false
}
