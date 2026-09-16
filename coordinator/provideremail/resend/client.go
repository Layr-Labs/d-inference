// Package resend implements only the Resend operations needed for provider
// audiences, draft broadcasts and an explicitly addressed test email.
package resend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

type Client struct {
	key      string
	baseURL  string
	http     *http.Client
	interval time.Duration
	mu       sync.Mutex
	next     time.Time
}

func New(key string) (*Client, error) {
	if key == "" {
		return nil, errors.New("RESEND_API_KEY is required")
	}
	return &Client{key: key, baseURL: "https://api.resend.com", interval: 600 * time.Millisecond,
		http: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

type APIError struct {
	Status int
}

func (e *APIError) Error() string {
	// Never echo a response body or request URL: either may contain addresses,
	// email content, or credentials. The Resend dashboard has detailed logs.
	return fmt.Sprintf("Resend returned HTTP %d; check the Resend logs", e.Status)
}

func wait(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(max(d, 0))
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (c *Client) pace(ctx context.Context) error {
	c.mu.Lock()
	d := time.Until(c.next)
	c.next = time.Now().Add(max(d, 0) + c.interval)
	c.mu.Unlock()
	return wait(ctx, d)
}

func (c *Client) request(ctx context.Context, method, path string, body, out any, idempotencyKey string) error {
	var raw []byte
	var err error
	if body != nil {
		raw, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	// Only reads and membership reconciliation are safe to retry without a
	// documented idempotency contract. Draft/segment/contact POSTs fail on an
	// ambiguous result; a rerun discovers existing resources before creating.
	safeRetry := method == http.MethodGet || method == http.MethodDelete || idempotencyKey != ""
	for attempt := 0; attempt < 4; attempt++ {
		if err := c.pace(ctx); err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, bytes.NewReader(raw))
		if err != nil {
			return errors.New("invalid Resend request")
		}
		req.Header.Set("Authorization", "Bearer "+c.key)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("User-Agent", "darkbloom-provider-emails/1")
		if idempotencyKey != "" {
			req.Header.Set("Idempotency-Key", idempotencyKey)
		}
		resp, err := c.http.Do(req)
		if err != nil {
			return errors.New("Resend request failed; outcome may be unknown, inspect before retrying")
		}
		data, readErr := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
		resp.Body.Close()
		if readErr != nil || len(data) > 4<<20 {
			return errors.New("invalid or oversized Resend response")
		}
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			if out != nil {
				if err := json.Unmarshal(data, out); err != nil {
					return errors.New("invalid Resend response JSON")
				}
			}
			return nil
		}
		retry := resp.StatusCode == 429 || safeRetry && resp.StatusCode >= 500
		if !retry || attempt == 3 {
			return &APIError{Status: resp.StatusCode}
		}
		delay := time.Second * time.Duration(1<<attempt)
		if seconds, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && seconds >= 0 {
			if seconds > 30 {
				return errors.New("Resend retry delay exceeds 30 seconds; try again later")
			}
			delay = max(delay, time.Duration(seconds)*time.Second)
		}
		if delay > 30*time.Second {
			return errors.New("Resend retry delay exceeds 30 seconds; try again later")
		}
		if err := wait(ctx, delay); err != nil {
			return err
		}
	}
	return errors.New("Resend retry limit reached")
}
