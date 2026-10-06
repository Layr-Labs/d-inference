package resume

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// codeResumeTransport is the live connection boundary for an encrypted resume
// proof. Identity matching and writes always use the current registration.
type Transport interface {
	MatchesIdentity(*registry.Provider, string, string) bool
	Send(context.Context, *registry.Provider, string, []byte) error
}

type ProviderTransport struct{}

func (ProviderTransport) MatchesIdentity(provider *registry.Provider, nodeKey, token string) bool {
	provider.Mu().Lock()
	identityCurrent := provider.PublicKey == nodeKey && provider.APNsDeviceToken == token
	provider.Mu().Unlock()
	return identityCurrent
}

func (ProviderTransport) Send(ctx context.Context, provider *registry.Provider, _ string, data []byte) error {
	return provider.WriteText(ctx, data)
}
