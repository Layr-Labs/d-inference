package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"syscall"
	"time"
)

// client is the Anthropic Messages API, in the smallest form this job needs. A
// dependency-free client keeps `tools/systemmap` a module with one non-stdlib
// import (go/packages), which is what lets it be built and run in isolation from
// the service it maps.
type client struct {
	http     *http.Client
	endpoint string
	key      string
	model    string
	maxTok   int
}

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type apiRequest struct {
	Model     string    `json:"model"`
	MaxTokens int       `json:"max_tokens"`
	System    string    `json:"system"`
	Messages  []message `json:"messages"`
}

type apiResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	StopReason string `json:"stop_reason"`
	Error      *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

// complete sends one prompt and returns the text of the reply.
func (c *client) complete(ctx context.Context, system string, turns []message) (string, error) {
	body, err := json.Marshal(apiRequest{
		Model:     c.model,
		MaxTokens: c.maxTok,
		System:    system,
		Messages:  turns,
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(c.endpoint, "/")+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("x-api-key", c.key)

	res, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", err
	}
	var parsed apiResponse
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return "", fmt.Errorf("http %d: response is not JSON: %s", res.StatusCode, clip(string(raw), 200))
	}
	if parsed.Error != nil {
		return "", fmt.Errorf("http %d: %s: %s", res.StatusCode, parsed.Error.Type, parsed.Error.Message)
	}
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("http %d: %s", res.StatusCode, clip(string(raw), 200))
	}
	var text strings.Builder
	for _, block := range parsed.Content {
		if block.Type == "text" {
			text.WriteString(block.Text)
		}
	}
	// A reply cut off at the budget is its own failure, and worth naming: the text is
	// truncated JSON, so every attempt fails the parser and the run ends reporting a
	// malformed answer when what it needed was a larger `-max-tokens`.
	if parsed.StopReason == "max_tokens" {
		return "", fmt.Errorf("completion hit the %d-token budget before finishing; raise -max-tokens", c.maxTok)
	}
	if strings.TrimSpace(text.String()) == "" {
		return "", fmt.Errorf("empty completion (stop_reason %q)", parsed.StopReason)
	}
	return text.String(), nil
}

// retryable reports whether a failure is worth another attempt: transport
// failures and the statuses the API documents as transient. A rejected prompt or
// a bad key is not retried, because the next attempt fails identically.
//
// Transport failures are recognised by type rather than by text. `net.Error`
// answers the timeout question directly, and matching the word instead missed the
// error `net/http` actually returns — `context deadline exceeded (Client.Timeout
// exceeded while awaiting headers)`, which contains no "timeout" at all — so the one
// failure most worth retrying was the one that never was. What is left to match by
// text is the API's own vocabulary, which arrives as a message and not as a type;
// the comparison is lower-cased because that message is not ours to spell.
func retryable(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		// The run's own budget, not the endpoint's problem: retrying spends the
		// remaining attempts on a context that is already done.
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, syscall.ECONNRESET) {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, sign := range []string{"http 429", "http 500", "http 502", "http 503", "http 504", "http 529",
		"overloaded", "rate_limit", "timeout", "connection reset", "unexpected eof", "eof"} {
		if strings.Contains(msg, sign) {
			return true
		}
	}
	return false
}

func backoff(attempt int) time.Duration {
	return time.Duration(1<<attempt) * time.Second
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
