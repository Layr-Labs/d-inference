package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// ProviderAuthBinding is the coordinator-validated device-token identity for
// one provider connection. TokenHash is a SHA-256 digest, never the raw bearer.
type ProviderAuthBinding struct {
	AccountID string
	TokenHash string
}

// RegisterAuthenticated publishes a provider with its account and token
// identity already attached. This avoids the routing/persistence window created
// by mutating AccountID after Register returned.
func (r *Registry) RegisterAuthenticated(
	id string,
	conn *websocket.Conn,
	msg *protocol.RegisterMessage,
	binding ProviderAuthBinding,
) *Provider {
	return r.register(id, conn, msg, binding)
}

type providerIdentityMatch struct {
	id       string
	provider *Provider
}

// DisconnectByAuthBinding snapshots every live connection carrying this exact
// token/account binding, then conditionally removes and tears each one down.
// New authenticated registrations are serialized with revocation by the API
// layer, and the pointer check prevents an old snapshot from evicting a
// replacement connection that reused the same session id.
func (r *Registry) DisconnectByAuthBinding(tokenHash, accountID string) int {
	if tokenHash == "" || accountID == "" {
		return 0
	}
	var matches []providerIdentityMatch
	r.mu.RLock()
	for id, provider := range r.providers {
		provider.mu.Lock()
		matched := provider.AuthTokenHash == tokenHash && provider.AccountID == accountID
		provider.mu.Unlock()
		if matched {
			matches = append(matches, providerIdentityMatch{id: id, provider: provider})
		}
	}
	r.mu.RUnlock()

	disconnected := 0
	for _, match := range matches {
		if r.disconnect(match.id, match.provider) {
			disconnected++
		}
	}
	return disconnected
}

// HasConnectedProviderForAccountIdentity reports whether this account still
// owns a live provider matching the serial (or the session id fallback used by
// never-attested records).
func (r *Registry) HasConnectedProviderForAccountIdentity(accountID, serialOrID string) bool {
	return len(r.providersForAccountIdentity(accountID, serialOrID)) != 0
}

// DisconnectProvidersForAccountIdentity evicts only matching sessions that are
// still owned by accountID. A transferred/reconnected provider under another
// account is never touched.
func (r *Registry) DisconnectProvidersForAccountIdentity(accountID, serialOrID string) int {
	matches := r.providersForAccountIdentity(accountID, serialOrID)
	disconnected := 0
	for _, match := range matches {
		if r.disconnect(match.id, match.provider) {
			disconnected++
		}
	}
	return disconnected
}

func (r *Registry) providersForAccountIdentity(accountID, serialOrID string) []providerIdentityMatch {
	if accountID == "" || serialOrID == "" {
		return nil
	}
	var matches []providerIdentityMatch
	r.mu.RLock()
	for id, provider := range r.providers {
		provider.mu.Lock()
		matchesAccount := provider.AccountID == accountID
		matchesIdentity := id == serialOrID ||
			(provider.AttestationResult != nil &&
				provider.AttestationResult.SerialNumber == serialOrID)
		provider.mu.Unlock()
		if matchesAccount && matchesIdentity {
			matches = append(matches, providerIdentityMatch{id: id, provider: provider})
		}
	}
	r.mu.RUnlock()
	return matches
}
