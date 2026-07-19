package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	stripeAutoWithdrawInterval = 15 * time.Minute
	stripeAutoWithdrawBatch    = 200
	stripeAutoWithdrawWorkers  = 8
	stripeAutoWithdrawHourUTC  = 9
	// Stripe may evict idempotency keys after 24 hours. Never replay a pending
	// transfer close to that boundary; stale rows move to manual reconciliation.
	stripeAutoWithdrawResumeWindow = 23 * time.Hour
)

var stripeAutoWithdrawNamespace = uuid.MustParse("153e2b49-6615-4de7-884f-a69c953d6173")

// handleStripeAutoWithdraw handles PUT /v1/billing/stripe/auto-withdraw.
// Only an interactive Privy session reaches this handler (route middleware).
func (s *Server) handleStripeAutoWithdraw(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || req.Enabled == nil {
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request_error", "enabled must be a boolean"))
		return
	}
	if *req.Enabled && (s.billing == nil || s.billing.StripeConnect() == nil) {
		writeJSON(w, http.StatusServiceUnavailable,
			errorResponse("billing_error", "Stripe Payouts not configured"))
		return
	}
	if *req.Enabled &&
		(user.StripeAccountID == "" || user.StripeAccountStatus != stripeStatusReady) {
		writeJSON(w, http.StatusConflict, errorResponse("not_onboarded",
			"link and verify a Stripe payout account before enabling automatic withdrawals"))
		return
	}

	now := time.Now().UTC()
	nextAt := nextStripeAutoWithdrawAt(now)
	if err := s.store.SetStripeAutoWithdraw(
		user.AccountID, user.StripeAccountID, *req.Enabled, now, nextAt,
	); err != nil {
		if errors.Is(err, store.ErrAutoWithdrawNotAuthorized) {
			writeJSON(w, http.StatusConflict, errorResponse("payout_destination_changed",
				"your Stripe payout destination changed — refresh and authorize it again"))
			return
		}
		s.logger.Error("stripe auto payout: preference update failed",
			"error", err, "account", shortAccountID(user.AccountID))
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "could not update automatic withdrawals"))
		return
	}

	updated, err := s.store.GetUserByAccountID(user.AccountID)
	if err != nil {
		s.logger.Error("stripe auto payout: preference reload failed",
			"error", err, "account", shortAccountID(user.AccountID))
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "automatic withdrawals were updated but status could not be loaded"))
		return
	}
	outcome := "disabled"
	if updated.StripeAutoWithdrawEnabled {
		outcome = "enabled"
	}
	s.ddIncr("billing.auto_withdraw.preference", []string{"outcome:" + outcome})
	s.logger.Info("stripe auto payout: preference updated",
		"account", shortAccountID(user.AccountID), "enabled", updated.StripeAutoWithdrawEnabled)
	writeJSON(w, http.StatusOK, stripeAutoWithdrawFields(updated))
}

func stripeAutoWithdrawFields(user *store.User) map[string]any {
	return map[string]any{
		"auto_withdraw_enabled":       user.StripeAutoWithdrawEnabled,
		"auto_withdraw_authorized_at": user.StripeAutoWithdrawAuthorizedAt,
		"auto_withdraw_next_at":       user.StripeAutoWithdrawNextAt,
		"auto_withdraw_cadence":       "weekly",
		"auto_withdraw_method":        "standard",
	}
}

// StartStripeAutoWithdrawWorker launches the periodic due-slot and crash-resume
// sweep. No-op when Stripe Connect is not configured.
func (s *Server) StartStripeAutoWithdrawWorker(ctx context.Context) {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		return
	}
	s.logger.Info("stripe automatic withdrawal worker started",
		"interval", stripeAutoWithdrawInterval.String(),
		"schedule", "Monday 09:00 UTC")
	saferun.Go(s.logger, "api.stripeAutoWithdrawWorker", func() {
		timer := time.NewTimer(time.Minute)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case now := <-timer.C:
			s.sweepStripeAutoWithdrawals(now.UTC())
		}

		ticker := time.NewTicker(stripeAutoWithdrawInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				s.sweepStripeAutoWithdrawals(now.UTC())
			}
		}
	})
}

func (s *Server) sweepStripeAutoWithdrawals(now time.Time) {
	s.resumePendingStripeAutoWithdrawals(now)

	users, err := s.billing.Store().ListUsersDueForStripeAutoWithdraw(
		now, stripeAutoWithdrawBatch,
	)
	if err != nil {
		s.logger.Error("stripe auto payout: list due users failed", "error", err)
		s.ddIncr("billing.auto_withdraw", []string{"outcome:list_failed"})
		return
	}
	s.runStripeAutoWithdrawBatch(len(users), "api.stripeAutoWithdrawDue", func(i int) {
		s.processDueStripeAutoWithdrawal(&users[i], now)
	})
}

func (s *Server) resumePendingStripeAutoWithdrawals(now time.Time) {
	pending, err := s.billing.Store().ListStripeWithdrawalsBySourceStatusAfter(
		store.StripeWithdrawalSourceAutomatic, "pending",
		now.Add(-stripeAutoWithdrawResumeWindow), stripeAutoWithdrawBatch,
	)
	if err != nil {
		s.logger.Error("stripe auto payout: list pending withdrawals failed", "error", err)
		s.ddIncr("billing.auto_withdraw", []string{"outcome:resume_list_failed"})
		return
	}
	s.runStripeAutoWithdrawBatch(len(pending), "api.stripeAutoWithdrawResume", func(i int) {
		wd := &pending[i]
		user := &store.User{
			AccountID:       wd.AccountID,
			StripeAccountID: wd.StripeAccountID,
		}
		result, payoutErr := s.executeStripeTransfer(stripeTransferRequest{
			User:            user,
			GrossMicroUSD:   wd.AmountMicroUSD,
			FeeMicroUSD:     wd.FeeMicroUSD,
			Method:          wd.Method,
			Source:          store.StripeWithdrawalSourceAutomatic,
			WithdrawalID:    wd.ID,
			ScheduledFor:    wd.ScheduledFor,
			TransferMessage: "Darkbloom weekly automatic withdrawal",
		})
		s.recordStripeAutoWithdrawResult(wd, result, payoutErr, "resume")
		if wd.ScheduledFor != nil && (result != nil || payoutErr != nil && payoutErr.Withdrawal != nil) {
			s.advanceStripeAutoWithdrawSchedule(wd.AccountID, *wd.ScheduledFor, now)
		}
	})
}

func (s *Server) processDueStripeAutoWithdrawal(user *store.User, now time.Time) {
	if user.StripeAutoWithdrawNextAt == nil {
		return
	}
	scheduledFor := user.StripeAutoWithdrawNextAt.UTC()
	withdrawalID := automaticStripeWithdrawalID(user.AccountID, scheduledFor)

	existing, _ := s.billing.Store().GetStripeWithdrawal(withdrawalID)
	amountMicroUSD := int64(0)
	if existing == nil {
		var err error
		amountMicroUSD, err = s.billing.Store().GetWithdrawableBalanceWithError(user.AccountID)
		if err != nil {
			s.logger.Warn("stripe auto payout: balance read failed",
				"error", err, "account", shortAccountID(user.AccountID))
			s.deferStripeAutoWithdrawSchedule(user.AccountID, scheduledFor, now.Add(time.Hour))
			s.ddIncr("billing.auto_withdraw", []string{"outcome:balance_read_failed"})
			return
		}
		if amountMicroUSD < billing.MinWithdrawMicroUSD {
			s.ddIncr("billing.auto_withdraw", []string{"outcome:below_minimum"})
			s.advanceStripeAutoWithdrawSchedule(user.AccountID, scheduledFor, now)
			return
		}
		if _, payoutErr := s.validateStripePayoutAccount(user, "standard"); payoutErr != nil {
			s.recordStripeAutoWithdrawResult(nil, nil, payoutErr, "precheck")
			if payoutErr.Code == "stripe_error" {
				s.deferStripeAutoWithdrawSchedule(user.AccountID, scheduledFor, now.Add(time.Hour))
			}
			return
		}
	} else {
		amountMicroUSD = existing.AmountMicroUSD
	}

	result, payoutErr := s.executeStripeTransfer(stripeTransferRequest{
		User:            user,
		GrossMicroUSD:   amountMicroUSD,
		Method:          "standard",
		Source:          store.StripeWithdrawalSourceAutomatic,
		WithdrawalID:    withdrawalID,
		ScheduledFor:    &scheduledFor,
		TransferMessage: "Darkbloom weekly automatic withdrawal",
	})
	s.recordStripeAutoWithdrawResult(existing, result, payoutErr, "scheduled")
	if result != nil || payoutErr != nil && payoutErr.Withdrawal != nil {
		s.advanceStripeAutoWithdrawSchedule(user.AccountID, scheduledFor, now)
	} else if payoutErr != nil &&
		!errors.Is(payoutErr, store.ErrStripeWithdrawalBusy) &&
		!errors.Is(payoutErr, store.ErrAutoWithdrawNotAuthorized) {
		s.deferStripeAutoWithdrawSchedule(
			user.AccountID, scheduledFor, now.Add(stripeAutoWithdrawInterval),
		)
	}
}

func (s *Server) runStripeAutoWithdrawBatch(count int, name string, fn func(int)) {
	if count == 0 {
		return
	}
	workers := min(stripeAutoWithdrawWorkers, count)
	jobs := make(chan int)
	var wg sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			defer wg.Done()
			for index := range jobs {
				func() {
					defer saferun.Recover(s.logger, name)
					fn(index)
				}()
			}
		}()
	}
	for index := range count {
		jobs <- index
	}
	close(jobs)
	wg.Wait()
}

func (s *Server) recordStripeAutoWithdrawResult(
	existing *store.StripeWithdrawal,
	result *stripeTransferResult,
	payoutErr *stripeTransferError,
	stage string,
) {
	if payoutErr != nil {
		outcome := payoutErr.Code
		if errors.Is(payoutErr, store.ErrAutoWithdrawNotAuthorized) {
			outcome = "authorization_changed"
		} else if errors.Is(payoutErr, store.ErrInsufficientBalance) {
			outcome = "balance_race"
		}
		s.ddIncr("billing.auto_withdraw", []string{
			"outcome:" + outcome,
			"stage:" + stage,
		})
		s.logger.Warn("stripe auto payout: attempt did not complete",
			"stage", stage, "outcome", outcome, "error", payoutErr)
		return
	}
	if result == nil || result.Withdrawal == nil {
		s.ddIncr("billing.auto_withdraw", []string{"outcome:empty_result", "stage:" + stage})
		return
	}
	outcome := result.Withdrawal.Status
	if existing != nil {
		outcome = "resumed_" + outcome
	}
	s.ddIncr("billing.auto_withdraw", []string{
		"outcome:" + outcome,
		"stage:" + stage,
	})
	s.ddHistogram("billing.auto_withdraw.amount_micro_usd",
		float64(result.Withdrawal.AmountMicroUSD), nil)
	s.logger.Info("stripe auto payout: withdrawal processed",
		"withdrawal_id", result.Withdrawal.ID,
		"account", shortAccountID(result.Withdrawal.AccountID),
		"status", result.Withdrawal.Status,
		"amount_micro_usd", result.Withdrawal.AmountMicroUSD)
}

func (s *Server) advanceStripeAutoWithdrawSchedule(accountID string, scheduledFor, now time.Time) {
	nextAt := nextStripeAutoWithdrawAt(now)
	s.moveStripeAutoWithdrawSchedule(accountID, scheduledFor, nextAt, "schedule_advanced")
}

func (s *Server) deferStripeAutoWithdrawSchedule(accountID string, scheduledFor, retryAt time.Time) {
	s.moveStripeAutoWithdrawSchedule(accountID, scheduledFor, retryAt, "retry_deferred")
}

func (s *Server) moveStripeAutoWithdrawSchedule(accountID string, scheduledFor, nextAt time.Time, outcome string) {
	advanced, err := s.billing.Store().AdvanceStripeAutoWithdraw(
		accountID, scheduledFor, nextAt,
	)
	if err != nil {
		s.logger.Error("stripe auto payout: advance schedule failed",
			"error", err, "account", shortAccountID(accountID))
		s.ddIncr("billing.auto_withdraw", []string{"outcome:schedule_advance_failed"})
		return
	}
	if advanced {
		s.ddIncr("billing.auto_withdraw", []string{"outcome:" + outcome})
	}
}

func nextStripeAutoWithdrawAt(after time.Time) time.Time {
	after = after.UTC()
	daysUntilMonday := (int(time.Monday) - int(after.Weekday()) + 7) % 7
	next := time.Date(
		after.Year(), after.Month(), after.Day()+daysUntilMonday,
		stripeAutoWithdrawHourUTC, 0, 0, 0, time.UTC,
	)
	if !next.After(after) {
		next = next.AddDate(0, 0, 7)
	}
	return next
}

func automaticStripeWithdrawalID(accountID string, scheduledFor time.Time) string {
	name := accountID + "\x00" + scheduledFor.UTC().Format(time.RFC3339Nano)
	return uuid.NewSHA1(stripeAutoWithdrawNamespace, []byte(name)).String()
}

func shortAccountID(accountID string) string {
	return accountID[:min(8, len(accountID))] + "..."
}
