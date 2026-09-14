package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
)

// CreateAccountLink returns a hosted onboarding URL the frontend should
// redirect to. Stripe handles the KYC + bank linking flow.
func (c *StripeConnect) CreateAccountLink(accountID, returnURL, refreshURL string) (string, error) {
	if c.secretKey == "" && !c.mockMode {
		return "", errors.New("stripe connect: not configured")
	}
	if accountID == "" || returnURL == "" || refreshURL == "" {
		return "", errors.New("stripe connect: account_id, return_url, refresh_url required")
	}

	if c.mockMode {
		return "https://connect.stripe.com/setup/mock/" + accountID + "?return=" + url.QueryEscape(returnURL), nil
	}

	form := url.Values{}
	form.Set("account", accountID)
	form.Set("type", "account_onboarding")
	form.Set("return_url", returnURL)
	form.Set("refresh_url", refreshURL)
	form.Set("collect", "eventually_due")

	body, err := c.do("POST", "/v1/account_links", form, "")
	if err != nil {
		return "", fmt.Errorf("stripe connect: create account link: %w", err)
	}
	var resp struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("stripe connect: parse account link: %w", err)
	}
	return resp.URL, nil
}

// CreateLoginLink returns a single-use URL into the connected account's
// Express Dashboard, where the account holder can change the bank account or
// debit card their payouts land in, review their connected balance, and see
// Stripe's own payout history.
//
// This is the only self-serve path for editing an already-onboarded Express
// account's payout destination. `account_onboarding` links (CreateAccountLink)
// collect outstanding requirements only, and an account with payouts enabled
// has none; Stripe rejects `account_update` links outright for accounts that
// have a Stripe-hosted dashboard, which every Express account does
// (https://docs.stripe.com/api/account_links/create).
//
// The returned URL is a bearer credential for the account holder's dashboard
// session. Redirect to it from an authenticated session only — never email,
// message, or log it (https://docs.stripe.com/connect/integrate-express-dashboard).
func (c *StripeConnect) CreateLoginLink(accountID string) (string, error) {
	if c.secretKey == "" && !c.mockMode {
		return "", errors.New("stripe connect: not configured")
	}
	if accountID == "" {
		return "", errors.New("stripe connect: account_id required")
	}

	if c.mockMode {
		return "https://connect.stripe.com/express/mock/" + accountID, nil
	}

	if err := validAccountID(accountID); err != nil {
		return "", err
	}
	body, err := c.do("POST", "/v1/accounts/"+accountID+"/login_links", url.Values{}, "")
	if err != nil {
		return "", fmt.Errorf("stripe connect: create login link: %w", err)
	}
	var resp struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("stripe connect: parse login link: %w", err)
	}
	if resp.URL == "" {
		return "", errors.New("stripe connect: login link response had no url")
	}
	return resp.URL, nil
}
