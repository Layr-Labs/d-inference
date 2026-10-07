package trust_test

import (
	"context"
	"encoding/json"

	coderesume "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/resume"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type resumeTransportFixture struct{ fixture *trustFixture }

func (t resumeTransportFixture) MatchesIdentity(provider *registry.Provider, key, token string) bool {
	if t.fixture.codeResumeBeforeIdentityCheck != nil {
		t.fixture.codeResumeBeforeIdentityCheck()
	}
	return (coderesume.ProviderTransport{}).MatchesIdentity(provider, key, token)
}

func (t resumeTransportFixture) Send(ctx context.Context, provider *registry.Provider, id string, data []byte) error {
	if t.fixture.codeResumeSender == nil {
		return (coderesume.ProviderTransport{}).Send(ctx, provider, id, data)
	}
	var message protocol.CodeAttestationResumeChallenge
	if err := json.Unmarshal(data, &message); err != nil {
		return err
	}
	return t.fixture.codeResumeSender(id, message)
}
