package payouts

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func withPrivyUser(r *http.Request, user *store.User) *http.Request {
	ctx := access.WithConsumer(r.Context(), user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}
