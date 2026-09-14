package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/accounts"
)

// Device code constants remain available to existing coordinator integrations.
const (
	DeviceCodeExpiry       = accounts.DeviceCodeExpiry
	DeviceCodePollInterval = accounts.DeviceCodePollInterval
)

// accountController binds stateless account operations to current router services.
// Routes retain one controller; store, console URL and admin policy stay live.
func (s *Server) accountController() *accounts.Controller {
	return accounts.New(accounts.Dependencies{
		Store:          func() accounts.Store { return s.store },
		Logger:         s.logger,
		ConsoleURL:     func() string { return s.consoleURL },
		KeyCache:       s.requestAuth,
		AuthorizeAdmin: s.requireAdminKey,
	})
}

func (s *Server) keyModelAllowed(ctx context.Context, model string) bool {
	return accounts.KeyModelAllowed(ctx, model)
}

func (s *Server) checkKeySpendCap(ctx context.Context, additionalMicroUSD int64) (string, bool) {
	return accounts.CheckKeySpendCap(ctx, additionalMicroUSD, s.store)
}
