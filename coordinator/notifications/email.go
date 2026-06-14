package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/mail"
	"strings"
	"time"
)

type Email struct {
	From           string
	To             string
	Subject        string
	Text           string
	HTML           string
	UnsubscribeURL string
}

type ResendClient struct {
	apiKey string
	client *http.Client
}

const resendAPIURL = "https://api.resend.com/emails"

const resendHTTPTimeout = 10 * time.Second

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

func NewResendClient(apiKey string) *ResendClient {
	return NewResendClientWithHTTPClient(apiKey, &http.Client{Timeout: resendHTTPTimeout})
}

func NewResendClientWithHTTPClient(apiKey string, client *http.Client) *ResendClient {
	apiKey = strings.TrimSpace(apiKey)
	if !validResendAPIKey(apiKey) {
		return nil
	}
	if client == nil || client.Timeout <= 0 {
		return nil
	}
	return &ResendClient{
		apiKey: apiKey,
		client: client,
	}
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
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
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

func validateEmail(email Email) error {
	if hasHeaderBreaks(email.From) || hasHeaderBreaks(email.To) || hasHeaderBreaks(email.Subject) || hasHeaderBreaks(email.UnsubscribeURL) {
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
	return nil
}

func hasHeaderBreaks(s string) bool {
	return strings.ContainsAny(s, "\r\n")
}
