package accounts_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func reqWithUser(method, target, body, accountID string) *http.Request {
	r := httptest.NewRequest(method, target, strings.NewReader(body))
	ctx := access.WithConsumer(r.Context(), accountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, &store.User{AccountID: accountID})
	return r.WithContext(ctx)
}
