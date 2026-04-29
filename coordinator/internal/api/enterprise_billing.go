package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
)

func (s *Server) StartEnterpriseInvoiceLoop(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = time.Hour
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if s.billing == nil || s.billing.Stripe() == nil {
				continue
			}
			accounts, err := s.store.ListDueEnterpriseAccounts(time.Now())
			if err != nil {
				s.logger.Error("enterprise invoice loop: list due failed", "error", err)
				continue
			}
			for _, result := range s.runEnterpriseInvoices(accounts, time.Now()) {
				if result.Error != "" {
					s.logger.Error("enterprise invoice loop: invoice failed", "account_id", result.AccountID, "error", result.Error)
				}
			}
		}
	}
}

type enterpriseAccountRequest struct {
	AccountID           string     `json:"account_id"`
	Status              *string    `json:"status"`
	BillingEmail        string     `json:"billing_email"`
	StripeCustomerID    string     `json:"stripe_customer_id"`
	Cadence             *string    `json:"cadence"`
	TermsDays           *int       `json:"terms_days"`
	CreditLimitMicroUSD *int64     `json:"credit_limit_micro_usd"`
	CurrentPeriodStart  *time.Time `json:"current_period_start"`
	NextInvoiceAt       *time.Time `json:"next_invoice_at"`
}

func (s *Server) handleAdminUpsertEnterpriseAccount(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req enterpriseAccountRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	account, err := s.enterpriseAccountFromRequest(req)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if existing, err := s.store.GetEnterpriseAccount(account.AccountID); err == nil {
		if req.Status == nil {
			account.Status = existing.Status
		}
		if req.Cadence == nil {
			account.Cadence = existing.Cadence
		}
		if req.CreditLimitMicroUSD == nil {
			account.CreditLimitMicroUSD = existing.CreditLimitMicroUSD
		}
		if strings.TrimSpace(req.StripeCustomerID) == "" {
			account.StripeCustomerID = existing.StripeCustomerID
		}
		account.AccruedMicroUSD = existing.AccruedMicroUSD
		account.ReservedMicroUSD = existing.ReservedMicroUSD
		account.OpenInvoiceMicroUSD = existing.OpenInvoiceMicroUSD
		account.RoundingCarryMicroUSD = existing.RoundingCarryMicroUSD
		account.CreatedAt = existing.CreatedAt
		if req.TermsDays == nil {
			account.TermsDays = existing.TermsDays
		}
		if req.CurrentPeriodStart == nil {
			account.CurrentPeriodStart = existing.CurrentPeriodStart
		}
		if req.NextInvoiceAt == nil {
			account.NextInvoiceAt = existing.NextInvoiceAt
		}
	}
	if err := s.store.UpsertEnterpriseAccount(account); err != nil {
		s.logger.Error("enterprise: upsert account failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save enterprise account"))
		return
	}
	saved, _ := s.store.GetEnterpriseAccount(account.AccountID)
	writeJSON(w, http.StatusOK, map[string]any{"account": saved})
}

func (s *Server) enterpriseAccountFromRequest(req enterpriseAccountRequest) (*store.EnterpriseAccount, error) {
	if strings.TrimSpace(req.AccountID) == "" {
		return nil, fmt.Errorf("account_id is required")
	}
	status := ""
	if req.Status != nil {
		status = *req.Status
	}
	if status == "" {
		status = store.EnterpriseStatusActive
	}
	if status != store.EnterpriseStatusActive && status != store.EnterpriseStatusDisabled {
		return nil, fmt.Errorf("status must be active or disabled")
	}
	if strings.TrimSpace(req.BillingEmail) == "" {
		return nil, fmt.Errorf("billing_email is required")
	}
	cadence := ""
	if req.Cadence != nil {
		cadence = *req.Cadence
	}
	if cadence == "" {
		cadence = store.EnterpriseCadenceMonthly
	}
	if cadence != store.EnterpriseCadenceWeekly && cadence != store.EnterpriseCadenceBiweekly && cadence != store.EnterpriseCadenceMonthly {
		return nil, fmt.Errorf("cadence must be weekly, biweekly, or monthly")
	}
	termsDays := 15
	if req.TermsDays != nil {
		termsDays = *req.TermsDays
	}
	if termsDays < 0 || termsDays > 90 {
		return nil, fmt.Errorf("terms_days must be between 0 and 90")
	}
	creditLimitMicroUSD := int64(0)
	if req.CreditLimitMicroUSD != nil {
		creditLimitMicroUSD = *req.CreditLimitMicroUSD
	}
	if creditLimitMicroUSD < 0 {
		return nil, fmt.Errorf("credit_limit_micro_usd cannot be negative")
	}
	now := time.Now()
	periodStart := now
	if req.CurrentPeriodStart != nil && !req.CurrentPeriodStart.IsZero() {
		periodStart = *req.CurrentPeriodStart
	}
	nextInvoiceAt := enterpriseNextInvoiceAt(periodStart, cadence)
	if req.NextInvoiceAt != nil && !req.NextInvoiceAt.IsZero() {
		nextInvoiceAt = *req.NextInvoiceAt
	}
	return &store.EnterpriseAccount{
		AccountID:           strings.TrimSpace(req.AccountID),
		Status:              status,
		BillingEmail:        strings.TrimSpace(req.BillingEmail),
		StripeCustomerID:    strings.TrimSpace(req.StripeCustomerID),
		Cadence:             cadence,
		TermsDays:           termsDays,
		CreditLimitMicroUSD: creditLimitMicroUSD,
		CurrentPeriodStart:  periodStart,
		NextInvoiceAt:       nextInvoiceAt,
	}, nil
}

func enterpriseNextInvoiceAt(start time.Time, cadence string) time.Time {
	switch cadence {
	case store.EnterpriseCadenceWeekly:
		return start.AddDate(0, 0, 7)
	case store.EnterpriseCadenceBiweekly:
		return start.AddDate(0, 0, 14)
	default:
		return start.AddDate(0, 1, 0)
	}
}

func (s *Server) handleAdminListEnterpriseAccounts(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	accounts, err := s.store.ListEnterpriseAccounts()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list enterprise accounts"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": accounts})
}

func (s *Server) handleEnterpriseStatus(w http.ResponseWriter, r *http.Request) {
	accountID := s.resolveAccountID(r)
	account, err := s.store.GetEnterpriseAccount(accountID)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false})
		return
	}
	invoices, _ := s.store.ListEnterpriseInvoices(accountID, 10)
	remaining := account.CreditLimitMicroUSD - account.OpenInvoiceMicroUSD - account.AccruedMicroUSD - account.ReservedMicroUSD - account.RoundingCarryMicroUSD
	if remaining < 0 {
		remaining = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":                    account.Status == store.EnterpriseStatusActive,
		"account":                    account,
		"recent_invoices":            invoices,
		"credit_remaining_micro_usd": remaining,
	})
}

func (s *Server) handleAdminRunEnterpriseInvoices(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	if s.billing == nil || s.billing.Stripe() == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("billing_error", "Stripe payments not configured"))
		return
	}
	var req struct {
		AccountID string `json:"account_id,omitempty"`
		Now       string `json:"now,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	now := time.Now()
	if req.Now != "" {
		if parsed, err := time.Parse(time.RFC3339, req.Now); err == nil {
			now = parsed
		}
	}
	var accounts []store.EnterpriseAccount
	if req.AccountID != "" {
		account, err := s.store.GetEnterpriseAccount(req.AccountID)
		if err != nil {
			writeJSON(w, http.StatusNotFound, errorResponse("not_found", "enterprise account not found"))
			return
		}
		accounts = []store.EnterpriseAccount{*account}
	} else {
		var err error
		accounts, err = s.store.ListDueEnterpriseAccounts(now)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list due accounts"))
			return
		}
	}
	results := s.runEnterpriseInvoices(accounts, now)
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

type enterpriseInvoiceRunResult struct {
	AccountID string `json:"account_id"`
	Skipped   bool   `json:"skipped,omitempty"`
	Reason    string `json:"reason,omitempty"`
	InvoiceID string `json:"invoice_id,omitempty"`
	Error     string `json:"error,omitempty"`
}

func (s *Server) runEnterpriseInvoices(accounts []store.EnterpriseAccount, now time.Time) []enterpriseInvoiceRunResult {
	results := make([]enterpriseInvoiceRunResult, 0, len(accounts))
	for _, account := range accounts {
		result := enterpriseInvoiceRunResult{AccountID: account.AccountID}
		if account.Status != store.EnterpriseStatusActive {
			result.Skipped = true
			result.Reason = "account_not_active"
			results = append(results, result)
			continue
		}
		if account.NextInvoiceAt.After(now) {
			result.Skipped = true
			result.Reason = "not_due"
			results = append(results, result)
			continue
		}
		totalMicro := account.AccruedMicroUSD + account.RoundingCarryMicroUSD
		amountCents := totalMicro / 10_000
		if amountCents <= 0 {
			if err := s.store.AdvanceEnterpriseInvoicePeriod(account.AccountID, account.NextInvoiceAt, enterpriseNextInvoiceAt(account.NextInvoiceAt, account.Cadence)); err != nil {
				result.Error = err.Error()
				results = append(results, result)
				continue
			}
			result.Skipped = true
			result.Reason = "below_cent"
			results = append(results, result)
			continue
		}
		inv, err := s.createEnterpriseInvoice(account, account.NextInvoiceAt, amountCents)
		if err != nil {
			result.Error = err.Error()
		} else {
			result.InvoiceID = inv.ID
		}
		results = append(results, result)
	}
	return results
}

func (s *Server) createEnterpriseInvoice(account store.EnterpriseAccount, periodEnd time.Time, amountCents int64) (*store.EnterpriseInvoice, error) {
	stripeCustomerID := account.StripeCustomerID
	if stripeCustomerID == "" {
		customerKey := "enterprise-customer-" + enterpriseStableID(account.AccountID)
		customer, err := s.billing.Stripe().CreateCustomerWithIdempotency(account.BillingEmail, account.AccountID, customerKey)
		if err != nil {
			return nil, err
		}
		stripeCustomerID = customer.ID
		if err := s.store.SetEnterpriseStripeCustomerID(account.AccountID, stripeCustomerID); err != nil {
			return nil, err
		}
	}

	internalID := enterpriseInvoiceID(account.AccountID, account.CurrentPeriodStart, periodEnd)
	billedMicro := amountCents * 10_000
	draft := &store.EnterpriseInvoice{
		ID:             internalID,
		AccountID:      account.AccountID,
		Status:         store.EnterpriseInvoiceStatusDraft,
		PeriodStart:    account.CurrentPeriodStart,
		PeriodEnd:      periodEnd,
		AmountMicroUSD: billedMicro,
		AmountCents:    amountCents,
		TermsDays:      account.TermsDays,
	}
	if err := s.store.CreateEnterpriseInvoiceDraft(draft); err != nil {
		return nil, err
	}
	desc := fmt.Sprintf("Darkbloom Enterprise usage %s - %s",
		account.CurrentPeriodStart.Format("2006-01-02"), periodEnd.Format("2006-01-02"))
	resp, err := s.billing.Stripe().CreateEnterpriseInvoice(billing.EnterpriseInvoiceRequest{
		CustomerID:     stripeCustomerID,
		AccountID:      account.AccountID,
		AmountCents:    amountCents,
		Currency:       "usd",
		Description:    desc,
		PeriodStart:    account.CurrentPeriodStart,
		PeriodEnd:      periodEnd,
		TermsDays:      account.TermsDays,
		IdempotencyKey: "enterprise-invoice-" + internalID,
		Metadata: map[string]string{
			"enterprise_invoice_id": internalID,
			"account_id":            account.AccountID,
			"period_start":          account.CurrentPeriodStart.Format(time.RFC3339),
			"period_end":            periodEnd.Format(time.RFC3339),
		},
	})
	if err != nil {
		return nil, err
	}
	if resp.AmountDueCents > 0 && resp.AmountDueCents != amountCents {
		return nil, fmt.Errorf("stripe invoice amount_due=%d does not match local amount=%d", resp.AmountDueCents, amountCents)
	}
	invoice := &store.EnterpriseInvoice{
		ID:                     internalID,
		AccountID:              account.AccountID,
		StripeInvoiceID:        resp.InvoiceID,
		StripeHostedInvoiceURL: resp.HostedInvoiceURL,
		StripeInvoicePDF:       resp.InvoicePDF,
		Status:                 normalizeStripeInvoiceStatus(resp.Status),
		PeriodStart:            account.CurrentPeriodStart,
		PeriodEnd:              periodEnd,
		AmountMicroUSD:         billedMicro,
		AmountCents:            amountCents,
		TermsDays:              account.TermsDays,
		DueAt:                  resp.DueAt,
		SentAt:                 resp.SentAt,
	}
	if err := s.store.CreateEnterpriseInvoice(invoice); err != nil {
		if existing, lookupErr := s.store.GetEnterpriseInvoiceByStripeID(resp.InvoiceID); lookupErr == nil {
			return existing, nil
		}
		return nil, err
	}
	return invoice, nil
}

func enterpriseInvoiceID(accountID string, periodStart, periodEnd time.Time) string {
	key := fmt.Sprintf("%s:%s:%s",
		accountID,
		periodStart.UTC().Format(time.RFC3339Nano),
		periodEnd.UTC().Format(time.RFC3339Nano),
	)
	return enterpriseStableID(key)
}

func enterpriseStableID(key string) string {
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte(key)).String()
}

func normalizeStripeInvoiceStatus(status string) string {
	switch status {
	case "paid":
		return store.EnterpriseInvoiceStatusPaid
	case "void":
		return store.EnterpriseInvoiceStatusVoid
	case "uncollectible":
		return store.EnterpriseInvoiceStatusUncollectible
	case "open":
		return store.EnterpriseInvoiceStatusOpen
	default:
		return store.EnterpriseInvoiceStatusDraft
	}
}
