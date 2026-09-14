package billing

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// controllerFixture supplies the mutable service lifecycle used by the former
// Server fixtures. Endpoint bodies run against the real services and memory
// store; middleware and authenticated mux tests remain in the parent API package.
type controllerFixture struct {
	*Controller
	configuredService *billingservice.Service
}

func newControllerFixture(st store.Store, logger *slog.Logger) *controllerFixture {
	fixture := &controllerFixture{}
	fixture.Controller = New(Dependencies{
		Store: st, Logger: logger,
		Service:     func() *billingservice.Service { return fixture.configuredService },
		BaseRewards: func() *baserewards.Engine { return nil },
	})
	return fixture
}

func (f *controllerFixture) SetBilling(service *billingservice.Service) {
	f.configuredService = service
}

// withPrivyUser attaches exactly the user and account context values used by
// the existing direct-handler fixtures; it does not replace endpoint auth policy.
func withPrivyUser(r *http.Request, user *store.User) *http.Request {
	ctx := requestcontext.WithAccountID(r.Context(), user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}
