package globalpayouts

import (
	"fmt"
	"slices"
	"strings"
	"time"
)

type Amount struct {
	Value    int64  `json:"value"`
	Currency string `json:"currency"`
}
type Recipient struct {
	ID       string `json:"id"`
	Identity struct {
		Country string `json:"country"`
	} `json:"identity"`
	Defaults struct {
		PayoutMethods map[string]string `json:"payout_methods"`
	} `json:"defaults"`
	Configuration struct {
		Recipient struct {
			DefaultOutboundDestination string `json:"default_outbound_destination"`
			Capabilities               struct {
				BankAccounts map[string]struct {
					Status string `json:"status"`
				} `json:"bank_accounts"`
			} `json:"capabilities"`
		} `json:"recipient"`
	} `json:"configuration"`
}

func (r *Recipient) Ready(country, capability string) bool {
	return r.ID != "" && strings.EqualFold(r.Identity.Country, country) && r.Configuration.Recipient.Capabilities.BankAccounts[capability].Status == "active"
}

type BankMethod struct {
	ID          string `json:"id"`
	Type        string `json:"type"`
	Restricted  bool   `json:"restricted"`
	BankAccount struct {
		Country                string   `json:"country"`
		Last4                  string   `json:"last4"`
		Archived               bool     `json:"archived"`
		SupportedCurrencies    []string `json:"supported_currencies"`
		EnabledDeliveryOptions []string `json:"enabled_delivery_options"`
	} `json:"bank_account"`
	UsageStatus struct {
		Payments string `json:"payments"`
	} `json:"usage_status"`
}

func (m BankMethod) Eligible(country, currency, capability string) bool {
	return m.ID != "" && m.Type == "bank_account" && !m.Restricted && !m.BankAccount.Archived && strings.EqualFold(m.BankAccount.Country, country) && m.UsageStatus.Payments == "eligible" && slices.Contains(m.BankAccount.SupportedCurrencies, strings.ToLower(currency)) && (len(m.BankAccount.EnabledDeliveryOptions) == 0 || slices.Contains(m.BankAccount.EnabledDeliveryOptions, capability))
}

type Source struct {
	FinancialAccount string `json:"financial_account"`
	Currency         string `json:"currency,omitempty"`
	Debited          Amount `json:"debited,omitempty"`
}
type Destination struct {
	Recipient    string `json:"recipient"`
	PayoutMethod string `json:"payout_method"`
	Currency     string `json:"currency,omitempty"`
	Credited     Amount `json:"credited,omitempty"`
}
type PaymentRequest struct {
	From        map[string]string `json:"from"`
	To          map[string]string `json:"to"`
	Amount      Amount            `json:"amount"`
	QuoteID     string            `json:"outbound_payment_quote,omitempty"`
	Description string            `json:"description,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
}

func NewRequest(financialAccount, recipient, method, currency string, cents int64) PaymentRequest {
	return PaymentRequest{From: map[string]string{"financial_account": financialAccount, "currency": "usd"}, To: map[string]string{"recipient": recipient, "payout_method": method, "currency": strings.ToLower(currency)}, Amount: Amount{Value: cents, Currency: "usd"}}
}

type Quote struct {
	ID      string      `json:"id"`
	Amount  Amount      `json:"amount"`
	From    Source      `json:"from"`
	To      Destination `json:"to"`
	FXQuote *struct {
		LockExpiresAt time.Time `json:"lock_expires_at"`
		LockStatus    string    `json:"lock_status"`
	} `json:"fx_quote"`
}

func (q Quote) Validate(req PaymentRequest) error {
	if !strings.HasPrefix(q.ID, "obpq_") || q.Amount != req.Amount || q.From.FinancialAccount != req.From["financial_account"] || q.From.Debited.Currency != "usd" || q.From.Debited.Value != req.Amount.Value || q.To.Recipient != req.To["recipient"] || q.To.PayoutMethod != req.To["payout_method"] || q.To.Credited.Currency != req.To["currency"] || q.To.Credited.Value <= 0 {
		return fmt.Errorf("Stripe quote does not match the requested withdrawal")
	}
	return nil
}

type Payment struct {
	ID                  string                          `json:"id"`
	Amount              Amount                          `json:"amount"`
	From                Source                          `json:"from"`
	To                  Destination                     `json:"to"`
	Status              string                          `json:"status"`
	StatusDetails       map[string]PaymentStatusDetails `json:"status_details"`
	ExpectedArrivalDate string                          `json:"expected_arrival_date"`
}

type PaymentStatusDetails struct {
	Reason string `json:"reason"`
}

func (p Payment) Validate(req PaymentRequest) error {
	if !strings.HasPrefix(p.ID, "obp_") || p.Amount != req.Amount || p.From.FinancialAccount != req.From["financial_account"] || p.To.Recipient != req.To["recipient"] || p.To.PayoutMethod != req.To["payout_method"] {
		return fmt.Errorf("Stripe payment does not match the withdrawal")
	}
	return nil
}
