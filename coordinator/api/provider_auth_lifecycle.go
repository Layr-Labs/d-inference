package api

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

var errProviderTokenRejected = errors.New("provider token rejected")

// registerProvider validates a device token and initializes its account binding
// before publishing the provider in the registry. The lifecycle mutex closes
// the validate/publish vs revoke/disconnect gap.
func (s *Server) registerProvider(
	providerID string,
	conn *websocket.Conn,
	msg *protocol.RegisterMessage,
) (*registry.Provider, *store.ProviderToken, error) {
	if msg.AuthToken == "" {
		return s.registry.Register(providerID, conn, msg), nil, nil
	}

	s.providerAuthLifecycleMu.Lock()
	defer s.providerAuthLifecycleMu.Unlock()

	token, err := s.store.GetProviderToken(msg.AuthToken)
	if err != nil || token == nil || !token.Active ||
		token.AccountID == "" || token.TokenHash == "" {
		return nil, nil, errProviderTokenRejected
	}
	provider := s.registry.RegisterAuthenticated(
		providerID,
		conn,
		msg,
		registry.ProviderAuthBinding{
			AccountID: token.AccountID,
			TokenHash: token.TokenHash,
		},
	)
	return provider, token, nil
}

// revokeProviderToken deactivates the durable credential and removes every live
// registry session authenticated by that exact token/account binding before it
// returns. Registration uses the same mutex, so neither ordering can strand a
// newly-published session after a successful revoke.
func (s *Server) revokeProviderToken(token string) (*store.ProviderToken, int, error) {
	s.providerAuthLifecycleMu.Lock()
	defer s.providerAuthLifecycleMu.Unlock()

	binding, err := s.store.RevokeProviderToken(token)
	if err != nil {
		return nil, 0, err
	}
	disconnected := s.registry.DisconnectByAuthBinding(
		binding.TokenHash,
		binding.AccountID,
	)
	return binding, disconnected, nil
}
