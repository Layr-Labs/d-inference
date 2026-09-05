// Package globalpayouts implements Stripe's bank-only Global Payouts API.
// It deliberately does not share Connect's transfer/sweep lifecycle.
package globalpayouts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const APIVersion = "2026-08-26.preview"

type Client struct {
	Key              string
	FinancialAccount string
	BaseURL          string
	HTTP             *http.Client
}

func New(key, financialAccount string) *Client {
	return &Client{Key: key, FinancialAccount: financialAccount, BaseURL: "https://api.stripe.com", HTTP: &http.Client{Timeout: 20 * time.Second}}
}

// Error never includes request bodies, credentials, or recipient details.
type Error struct {
	Status int
	Code   string
}

func (e *Error) Error() string {
	return fmt.Sprintf("Stripe Global Payouts: HTTP %d (%s)", e.Status, e.Code)
}

// Only explicit validation/authentication failures prove that no payout was
// created. A 409, rate limit, server error, or transport error is ambiguous.
func (e *Error) Definitive() bool {
	return e.Code != "idempotency_error" && e.Code != "idempotency_conflict" && (e.Status == 400 || e.Status == 401 || e.Status == 403 || e.Status == 404 || e.Status == 422)
}

func (c *Client) do(ctx context.Context, method, path, account, key string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Key)
	req.Header.Set("Stripe-Version", APIVersion)
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	if account != "" {
		req.Header.Set("Stripe-Context", account)
	}
	r, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("Stripe Global Payouts transport: %w", err)
	}
	defer r.Body.Close()
	b, err := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	if err != nil {
		return err
	}
	if r.StatusCode < 200 || r.StatusCode >= 300 {
		var envelope struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		_ = json.Unmarshal(b, &envelope)
		return &Error{Status: r.StatusCode, Code: envelope.Error.Code}
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("Stripe Global Payouts response: %w", err)
	}
	return nil
}

func (c *Client) CreateRecipient(ctx context.Context, email, country, capability, key string) (*Recipient, error) {
	body := map[string]any{"contact_email": email, "identity": map[string]any{"country": strings.ToLower(country), "entity_type": "individual"}, "configuration": map[string]any{"recipient": map[string]any{"capabilities": map[string]any{"bank_accounts": map[string]any{capability: map[string]bool{"requested": true}}}}}, "include": []string{"identity", "configuration.recipient", "requirements", "defaults"}}
	var result Recipient
	err := c.do(ctx, "POST", "/v2/core/accounts", "", key, body, &result)
	return &result, err
}

func (c *Client) Recipient(ctx context.Context, id string) (*Recipient, error) {
	q := url.Values{}
	for i, field := range []string{"identity", "configuration.recipient", "requirements", "defaults"} {
		q.Set(fmt.Sprintf("include[%d]", i), field)
	}
	var result Recipient
	err := c.do(ctx, "GET", "/v2/core/accounts/"+url.PathEscape(id)+"?"+q.Encode(), "", "", nil, &result)
	return &result, err
}

func (c *Client) OnboardingLink(ctx context.Context, id, returnURL, refreshURL string) (string, error) {
	link, err := c.recipientLink(ctx, id, returnURL, refreshURL, "account_onboarding")
	// Stripe rejects onboarding links after a recipient has completed onboarding,
	// including when the bank later needs attention. The same authenticated user
	// must receive an account_update link to repair or change that destination.
	var apiErr *Error
	if errors.As(err, &apiErr) && apiErr.Status == 400 && apiErr.Code == "invalid_fields" {
		return c.recipientLink(ctx, id, returnURL, refreshURL, "account_update")
	}
	return link, err
}

func (c *Client) recipientLink(ctx context.Context, id, returnURL, refreshURL, useCase string) (string, error) {
	body := map[string]any{"account": id, "use_case": map[string]any{"type": useCase, useCase: map[string]any{"configurations": []string{"recipient"}, "return_url": returnURL, "refresh_url": refreshURL}}}
	var result struct {
		URL string `json:"url"`
	}
	err := c.do(ctx, "POST", "/v2/core/account_links", "", "", body, &result)
	if err == nil && result.URL == "" {
		err = fmt.Errorf("Stripe returned an empty onboarding link")
	}
	return result.URL, err
}

func (c *Client) BankMethod(ctx context.Context, r *Recipient, country, currency, capability string) (*BankMethod, error) {
	var page struct {
		Data        []BankMethod `json:"data"`
		NextPageURL string       `json:"next_page_url"`
	}
	err := c.do(ctx, "GET", "/v2/money_management/payout_methods?limit=100", r.ID, "", nil, &page)
	if err != nil {
		return nil, err
	}
	var eligible []BankMethod
	for _, m := range page.Data {
		if m.Eligible(country, currency, capability) {
			eligible = append(eligible, m)
		}
	}
	preferred := r.Defaults.PayoutMethods[strings.ToLower(currency)]
	if preferred == "" {
		preferred = r.Configuration.Recipient.DefaultOutboundDestination
	}
	for _, m := range eligible {
		if m.ID == preferred {
			return &m, nil
		}
	}
	// Never silently choose a different bank when multiple destinations exist.
	if len(eligible) == 1 && preferred == "" && page.NextPageURL == "" {
		return &eligible[0], nil
	}
	return nil, fmt.Errorf("select an eligible default bank account in Stripe")
}

func (c *Client) Quote(ctx context.Context, request PaymentRequest) (*Quote, error) {
	var quote Quote
	err := c.do(ctx, "POST", "/v2/money_management/outbound_payment_quotes", "", "", request, &quote)
	return &quote, err
}
func (c *Client) Send(ctx context.Context, request json.RawMessage, key string) (*Payment, error) {
	var p Payment
	err := c.do(ctx, "POST", "/v2/money_management/outbound_payments", "", key, request, &p)
	return &p, err
}
func (c *Client) Payment(ctx context.Context, id string) (*Payment, error) {
	var p Payment
	err := c.do(ctx, "GET", "/v2/money_management/outbound_payments/"+url.PathEscape(id), "", "", nil, &p)
	return &p, err
}
