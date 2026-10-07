package trust_test

import (
	"context"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	coderesume "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/resume"
	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type unansweredResumeTransport struct{ coderesume.ProviderTransport }

func (unansweredResumeTransport) Send(context.Context, *registry.Provider, string, []byte) error {
	return nil
}

func TestCodeAttestResumeTimeoutUsesConfiguredClock(t *testing.T) {
	policy := identitystate.NewPolicy(production.CodeAttestResponseTimeout, time.Millisecond)
	policy.Now = func() time.Time { return time.Now().Add(time.Hour) }
	throttle := codeidentity.NewThrottle(policy)
	recovered := make(chan struct{})
	manager := coderesume.New(throttle, quietLogger(), unansweredResumeTransport{}, func(context.Context, string, *registry.Provider) {
		close(recovered)
	})
	key, _, _, seKey := providerKeyMaterial(t)
	provider := newCodeAttestProvider(key, seKey)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if !manager.SendCodeIdentityResumeChallenge(ctx, provider.ID, provider, key, seKey, provider.APNsDeviceToken, throttle.PublicationGeneration()) {
		t.Fatal("resume challenge was not handed to the transport")
	}
	select {
	case <-recovered:
	case <-ctx.Done():
		t.Fatal("resume timeout used the wall clock instead of the configured proof clock")
	}
}
