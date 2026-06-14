package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/mail"
	"net/url"
	"strings"
	"time"

	"golang.org/x/net/http/httpguts"
)

type Email struct {
	From           string
	To             string
	Subject        string
	Text           string
	HTML           string
	UnsubscribeURL string
}

type EmailSender interface {
	Send(context.Context, Email) error
}

type EmailSenderFunc func(context.Context, Email) error

func (f EmailSenderFunc) Send(ctx context.Context, email Email) error {
	return f(ctx, email)
}

type ResendClient struct {
	apiKey string
	client *http.Client
}

const resendAPIURL = "https://api.resend.com/emails"

type resendEmailPayload struct {
	From    string              `json:"from"`
	To      []string            `json:"to"`
	Subject string              `json:"subject"`
	Text    string              `json:"text"`
	HTML    string              `json:"html"`
	Headers *resendEmailHeaders `json:"headers,omitempty"`
}

type resendEmailHeaders struct {
	ListUnsubscribe     string `json:"List-Unsubscribe,omitempty"`
	ListUnsubscribePost string `json:"List-Unsubscribe-Post,omitempty"`
}

func NewResendClient(apiKey string) (*ResendClient, error) {
	apiKey, ok := validatedResendAPIKey(apiKey)
	if !ok {
		return nil, fmt.Errorf("resend api key has an invalid format")
	}
	return &ResendClient{
		apiKey: apiKey,
		client: &http.Client{Timeout: 10 * time.Second},
	}, nil
}

func (c *ResendClient) Send(ctx context.Context, email Email) error {
	if c == nil {
		return fmt.Errorf("resend api key not configured")
	}
	if err := validateEmail(email); err != nil {
		return err
	}
	payload := resendEmailPayload{
		From:    email.From,
		To:      []string{email.To},
		Subject: email.Subject,
		Text:    email.Text,
		HTML:    email.HTML,
	}
	if email.UnsubscribeURL != "" {
		payload.Headers = &resendEmailHeaders{
			ListUnsubscribe:     "<" + email.UnsubscribeURL + ">",
			ListUnsubscribePost: "List-Unsubscribe=One-Click",
		}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, resendAPIURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	authorization, err := resendAuthorization(c.apiKey)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", authorization)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("resend returned %s", resp.Status)
	}
	return nil
}

func resendAuthorization(apiKey string) (string, error) {
	apiKey, ok := validatedResendAPIKey(apiKey)
	if !ok {
		return "", fmt.Errorf("resend api key has an invalid format")
	}
	authorization := "Bearer " + apiKey
	if !httpguts.ValidHeaderFieldValue(authorization) {
		return "", fmt.Errorf("resend api key has an invalid format")
	}
	return authorization, nil
}

func validateEmail(email Email) error {
	if !validEmailHeaderValue(email.From) || !validEmailHeaderValue(email.To) || !validEmailHeaderValue(email.Subject) || !validEmailHeaderValue(email.UnsubscribeURL) {
		return fmt.Errorf("email contains invalid header characters")
	}
	if strings.TrimSpace(email.Subject) == "" {
		return fmt.Errorf("email subject is required")
	}
	if _, err := mail.ParseAddress(email.From); err != nil {
		return fmt.Errorf("email from address is invalid: %w", err)
	}
	to, err := mail.ParseAddress(email.To)
	if err != nil || to.Address != email.To {
		return fmt.Errorf("email to address is invalid")
	}
	if email.UnsubscribeURL != "" {
		u, err := url.Parse(email.UnsubscribeURL)
		if err != nil || u.Scheme != "https" || u.Host == "" || strings.ContainsAny(email.UnsubscribeURL, "<>,") {
			return fmt.Errorf("email unsubscribe url is invalid")
		}
	}
	return nil
}

func validEmailHeaderValue(s string) bool {
	if strings.Contains(s, "\u2028") || strings.Contains(s, "\u2029") {
		return false
	}
	return httpguts.ValidHeaderFieldValue(s)
}
