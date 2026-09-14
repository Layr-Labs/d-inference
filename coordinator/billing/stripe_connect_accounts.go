package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// ExpressAccount captures the subset of fields we care about on a Stripe
// connected account.
type ExpressAccount struct {
	ID               string
	Email            string
	Country          string // ISO 3166-1 alpha-2 the account is locked to
	DefaultCurrency  string // lowercase ISO currency the balance settles in (e.g. "usd", "eur")
	ServiceAgreement string // "full" | "recipient" — immutable after acceptance
	PayoutInterval   string // settings.payouts.schedule.interval: "daily" | "weekly" | "monthly" | "manual"
	ChargesEnabled   bool
	PayoutsEnabled   bool
	DetailsSubmitted bool
	CurrentlyDue     []string // requirements blocking the account from being live
	DisabledReason   string   // populated when Stripe permanently disables the account
	DestinationType  string   // "bank" | "card" | ""
	DestinationLast4 string
	DestinationCard  string // brand for cards (e.g. "visa")
	InstantEligible  bool   // debit card destination supports Instant Payouts
}

// CreateExpressAccountParams gates which prefilled fields we pass to Stripe on
// account creation. Email/first/last come from Privy; country should come from
// the onboarding UI because Stripe locks it once the connected account exists.
type CreateExpressAccountParams struct {
	Email     string
	FirstName string
	LastName  string
	Country   string // ISO 3166-1 alpha-2 — empty means "use platform default"
}

// CreateExpressAccount creates a Stripe Express connected account.
//
// The service agreement depends on the account country (see stripe_regions.go):
//
//   - `full` (US/CA/UK/EEA/CH): we request `transfers` + `card_payments`.
//     Stripe's Connect Express flow requires `card_payments` unless the
//     platform has been pre-approved for transfers-only. We never charge
//     cards on the user's behalf — the capability just sits enabled.
//   - `recipient` (everywhere else): we set
//     tos_acceptance[service_agreement]=recipient and request ONLY
//     `transfers` — `card_payments` is incompatible with the recipient
//     agreement and Stripe rejects the account creation if requested.
//
// Payouts ride Stripe's automatic daily schedule: the platform transfers to
// the connected account and Stripe sweeps the balance to the user's bank in
// their local currency. Do NOT set the schedule to "manual" — manual-schedule
// accounts strand funds when our payouts.create call fails (wrong currency,
// funds not yet available, …) and the user sees "Contact <platform> to get
// paid out" in their Stripe dashboard with no way to self-serve.
func (c *StripeConnect) CreateExpressAccount(params CreateExpressAccountParams) (*ExpressAccount, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	country := params.Country
	if country == "" {
		country = c.platformCountry
	}
	agreement := RequiredServiceAgreement(c.platformCountry, country)

	if c.mockMode {
		mockID := "acct_mock_" + strings.ReplaceAll(params.Email, "@", "_at_")
		return &ExpressAccount{
			ID:               mockID,
			Email:            params.Email,
			Country:          country,
			ServiceAgreement: agreement,
			PayoutInterval:   "daily",
			ChargesEnabled:   false,
			PayoutsEnabled:   false,
			DetailsSubmitted: false,
		}, nil
	}

	form := url.Values{}
	form.Set("type", "express")
	form.Set("country", country)
	form.Set("capabilities[transfers][requested]", "true")
	if agreement == ServiceAgreementRecipient {
		form.Set("tos_acceptance[service_agreement]", ServiceAgreementRecipient)
	} else {
		form.Set("capabilities[card_payments][requested]", "true")
	}
	form.Set("business_type", "individual")
	if params.Email != "" {
		form.Set("email", params.Email)
		form.Set("individual[email]", params.Email)
	}
	if params.FirstName != "" {
		form.Set("individual[first_name]", params.FirstName)
	}
	if params.LastName != "" {
		form.Set("individual[last_name]", params.LastName)
	}
	// Stripe sweeps the connected balance to the user's bank automatically.
	setAutoPayoutSchedule(form, country)

	body, err := c.do("POST", "/v1/accounts", form, "")
	if err != nil {
		return nil, fmt.Errorf("stripe connect: create account: %w", err)
	}
	return parseAccount(body)
}

// setAutoPayoutSchedule writes the automatic payout-schedule form values for
// a connected account country. Japan doesn't support daily automatic payouts
// (weekly/monthly are the automatic options), so JP accounts sweep weekly,
// anchored on Monday; everywhere else uses daily.
func setAutoPayoutSchedule(form url.Values, country string) {
	if strings.EqualFold(strings.TrimSpace(country), "JP") {
		form.Set("settings[payouts][schedule][interval]", "weekly")
		form.Set("settings[payouts][schedule][weekly_anchor]", "monday")
		return
	}
	form.Set("settings[payouts][schedule][interval]", "daily")
}

// UpdateAccountPayoutScheduleAuto flips a connected account's payout schedule
// to automatic sweeps (daily, or weekly for countries where Stripe doesn't
// offer daily — see setAutoPayoutSchedule). Used to self-heal accounts
// created by older code with a "manual" schedule, which stranded transferred
// funds in the connected account balance. Idempotent — safe to call on
// accounts already on an automatic schedule.
func (c *StripeConnect) UpdateAccountPayoutScheduleAuto(accountID, country string) error {
	if c.secretKey == "" && !c.mockMode {
		return errors.New("stripe connect: not configured")
	}
	if accountID == "" {
		return errors.New("stripe connect: account_id required")
	}
	if c.mockMode {
		return nil
	}
	if err := validAccountID(accountID); err != nil {
		return err
	}
	form := url.Values{}
	setAutoPayoutSchedule(form, country)
	if _, err := c.do("POST", "/v1/accounts/"+accountID, form, ""); err != nil {
		return fmt.Errorf("stripe connect: update payout schedule: %w", err)
	}
	return nil
}

// GetAccount fetches the latest account state from Stripe. We use this when the
// user lands back on the billing page after onboarding so we can render the
// "ready" / "needs more info" state without waiting for the webhook.
func (c *StripeConnect) GetAccount(accountID string) (*ExpressAccount, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	if accountID == "" {
		return nil, errors.New("stripe connect: account_id required")
	}

	if c.mockMode {
		// Mock-mode account is "ready" so devs can exercise withdrawals.
		return &ExpressAccount{
			ID:               accountID,
			Country:          c.platformCountry,
			DefaultCurrency:  "usd",
			ServiceAgreement: ServiceAgreementFull,
			PayoutInterval:   "daily",
			ChargesEnabled:   true,
			PayoutsEnabled:   true,
			DetailsSubmitted: true,
			DestinationType:  "bank",
			DestinationLast4: "4242",
		}, nil
	}

	if err := validAccountID(accountID); err != nil {
		return nil, err
	}
	body, err := c.do("GET", "/v1/accounts/"+accountID, nil, "")
	if err != nil {
		return nil, fmt.Errorf("stripe connect: get account: %w", err)
	}
	return parseAccount(body)
}

// parseAccount maps the raw account JSON onto our trimmed ExpressAccount type.
// It pulls the destination (bank account or debit card) from external_accounts
// when present so the UI can show "Chase ••4821".
func parseAccount(body []byte) (*ExpressAccount, error) {
	var resp struct {
		ID               string `json:"id"`
		Email            string `json:"email"`
		Country          string `json:"country"`
		DefaultCurrency  string `json:"default_currency"`
		ChargesEnabled   bool   `json:"charges_enabled"`
		PayoutsEnabled   bool   `json:"payouts_enabled"`
		DetailsSubmitted bool   `json:"details_submitted"`
		TOSAcceptance    struct {
			ServiceAgreement string `json:"service_agreement"`
		} `json:"tos_acceptance"`
		Settings struct {
			Payouts struct {
				Schedule struct {
					Interval string `json:"interval"`
				} `json:"schedule"`
			} `json:"payouts"`
		} `json:"settings"`
		Requirements struct {
			CurrentlyDue   []string `json:"currently_due"`
			DisabledReason string   `json:"disabled_reason"`
		} `json:"requirements"`
		ExternalAccounts struct {
			Data []struct {
				Object             string `json:"object"` // "bank_account" | "card"
				Last4              string `json:"last4"`
				Brand              string `json:"brand"`
				Funding            string `json:"funding"`
				DefaultForCurrency bool   `json:"default_for_currency"`
			} `json:"data"`
		} `json:"external_accounts"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("parse account: %w", err)
	}

	acct := &ExpressAccount{
		ID:               resp.ID,
		Email:            resp.Email,
		Country:          resp.Country,
		DefaultCurrency:  resp.DefaultCurrency,
		ServiceAgreement: resp.TOSAcceptance.ServiceAgreement,
		PayoutInterval:   resp.Settings.Payouts.Schedule.Interval,
		ChargesEnabled:   resp.ChargesEnabled,
		PayoutsEnabled:   resp.PayoutsEnabled,
		DetailsSubmitted: resp.DetailsSubmitted,
		CurrentlyDue:     resp.Requirements.CurrentlyDue,
		DisabledReason:   resp.Requirements.DisabledReason,
	}

	// Pick the default external account (or the first one) as the destination
	// we display. Instant Payouts only work against debit cards.
	if len(resp.ExternalAccounts.Data) > 0 {
		pick := &resp.ExternalAccounts.Data[0]
		for i := range resp.ExternalAccounts.Data {
			if resp.ExternalAccounts.Data[i].DefaultForCurrency {
				pick = &resp.ExternalAccounts.Data[i]
				break
			}
		}
		switch pick.Object {
		case "bank_account":
			acct.DestinationType = "bank"
		case "card":
			acct.DestinationType = "card"
			acct.DestinationCard = pick.Brand
			// Stripe only supports Instant Payouts to debit cards.
			if strings.EqualFold(pick.Funding, "debit") {
				acct.InstantEligible = true
			}
		}
		acct.DestinationLast4 = pick.Last4
	}
	return acct, nil
}
