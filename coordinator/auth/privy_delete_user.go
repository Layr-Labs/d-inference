package auth

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// ErrPrivyUserNotFound is DeleteUser's result when Privy has no user with the
// ID: Privy answers 404.
var ErrPrivyUserNotFound = errors.New("privy: user not found")

// DeleteUser deletes the Privy user with the Privy user ID (DID). Privy
// documents DELETE https://auth.privy.io/api/v1/users/<did> with Basic auth
// (app ID and app secret) and the privy-app-id header; 204 means deleted and
// 404 means no such user
// (https://docs.privy.io/user-management/users/managing-users/deleting-users).
// The returned error never holds the user ID, because the erasure status API
// shows it.
func (p *PrivyAuth) DeleteUser(ctx context.Context, privyUserID string) error {
	if p.appSecret == "" {
		return errors.New("privy: app_secret required for REST API calls")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete,
		"https://auth.privy.io/api/v1/users/"+url.PathEscape(privyUserID), nil)
	if err != nil {
		return errors.New("privy: build delete user request")
	}
	req.SetBasicAuth(p.appID, p.appSecret)
	req.Header.Set("Privy-App-Id", p.appID)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		// A *url.Error names the URL, which holds the user ID.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fmt.Errorf("privy: delete user request failed: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	switch resp.StatusCode {
	case http.StatusNoContent:
		return nil
	case http.StatusNotFound:
		return ErrPrivyUserNotFound
	}
	return fmt.Errorf("privy: delete user returned status %d", resp.StatusCode)
}
