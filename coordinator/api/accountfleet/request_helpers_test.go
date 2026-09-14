package accountfleet

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reqWithUser builds a request whose context carries an authenticated user,
// simulating what requirePrivyAuth installs (so we can unit-test the handlers
// without minting a real Privy JWT).
func reqWithUser(method, target, body, accountID string) *http.Request {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, target, nil)
	} else {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
	}
	ctx := context.WithValue(r.Context(), auth.CtxKeyUser, &store.User{AccountID: accountID})
	ctx = requestcontext.WithAccountID(ctx, accountID)
	return r.WithContext(ctx)
}
