package globalpayouts

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"
)

const bankMethodsPath = "/v2/money_management/payout_methods"

func (c *Client) bankMethodsNextPage(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("invalid bank-method pagination URL")
	}
	base, err := url.Parse(c.BaseURL)
	if err != nil {
		return "", err
	}
	if u.User != nil || u.Fragment != "" || u.Path != bankMethodsPath || (u.Host != "" && (u.Host != base.Host || u.Scheme != base.Scheme)) || (u.Scheme != "" && u.Host == "") {
		return "", fmt.Errorf("unexpected bank-method pagination URL")
	}
	return u.RequestURI(), nil
}

func (c *Client) BankMethod(ctx context.Context, r *Recipient, country, currency, capability string) (*BankMethod, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	preferred := r.Defaults.PayoutMethods[strings.ToLower(currency)]
	if preferred == "" {
		preferred = r.Configuration.Recipient.DefaultOutboundDestination
	}
	path := bankMethodsPath + "?limit=100"
	seen := map[string]bool{}
	eligible := map[string]BankMethod{}
	for pageNumber := 0; pageNumber < 100; pageNumber++ {
		if seen[path] {
			return nil, fmt.Errorf("bank-method pagination repeated a page")
		}
		seen[path] = true
		var page struct {
			Data        []BankMethod `json:"data"`
			NextPageURL string       `json:"next_page_url"`
		}
		if err := c.do(ctx, "GET", path, r.ID, "", nil, &page); err != nil {
			return nil, err
		}
		for _, m := range page.Data {
			if !m.Eligible(country, currency, capability) {
				continue
			}
			if m.ID == preferred {
				return &m, nil
			}
			if preferred == "" {
				eligible[m.ID] = m
			}
		}
		if preferred == "" && len(eligible) > 1 {
			return nil, ErrNoEligibleBankMethod
		}
		if page.NextPageURL == "" {
			if preferred == "" && len(eligible) == 1 {
				for _, m := range eligible {
					return &m, nil
				}
			}
			return nil, ErrNoEligibleBankMethod
		}
		var err error
		path, err = c.bankMethodsNextPage(page.NextPageURL)
		if err != nil {
			return nil, err
		}
	}
	return nil, fmt.Errorf("bank-method pagination exceeded the page limit")
}
