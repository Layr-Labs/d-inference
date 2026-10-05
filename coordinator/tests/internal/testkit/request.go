package testkit

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

func NewAuthRequest(t testing.TB, ctx context.Context, url, body, key string) (*http.Request, error) {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	return req, nil
}
