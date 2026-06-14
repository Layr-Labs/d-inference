package notifications

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

type Email struct {
	From           string
	To             string
	Subject        string
	Text           string
	HTML           string
	UnsubscribeURL string
}

type EmailClient interface {
	Send(ctx context.Context, email Email) error
}

type ResendClient struct {
	apiKey string
	client *http.Client
}

const resendAPIURL = "https://api.resend.com/emails"

type resendEmailPayload struct {
	From    string            `json:"from"`
	To      []string          `json:"to"`
	Subject string            `json:"subject"`
	Text    string            `json:"text"`
	HTML    string            `json:"html"`
	Headers map[string]string `json:"headers,omitempty"`
}

func NewResendClient(apiKey string) *ResendClient {
	return NewResendClientWithHTTPClient(apiKey, http.DefaultClient)
}

func NewResendClientWithHTTPClient(apiKey string, client *http.Client) *ResendClient {
	if client == nil {
		client = http.DefaultClient
	}
	return &ResendClient{
		apiKey: strings.TrimSpace(apiKey),
		client: client,
	}
}

func (c *ResendClient) Send(ctx context.Context, email Email) error {
	if c == nil || !validResendAPIKey(c.apiKey) {
		return fmt.Errorf("resend api key not configured")
	}
	payload := resendEmailPayload{
		From:    email.From,
		To:      []string{email.To},
		Subject: email.Subject,
		Text:    email.Text,
		HTML:    email.HTML,
	}
	if email.UnsubscribeURL != "" {
		payload.Headers = map[string]string{
			"List-Unsubscribe":      "<" + email.UnsubscribeURL + ">",
			"List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
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
