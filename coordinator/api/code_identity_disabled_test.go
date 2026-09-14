package api

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCodeIdentityDisabledServerEntryPoints(t *testing.T) {
	for _, tc := range []struct {
		name string
		run  func(*Server, *registry.Provider)
	}{
		{"loop", func(s *Server, p *registry.Provider) {
			s.codeAttestLoop(context.Background(), p.ID, p)
		}},
		{"heartbeat_rearm", func(s *Server, p *registry.Provider) {
			s.maybeRearmCodeAttest(context.Background(), p.ID, p, &protocol.HeartbeatMessage{
				APNsDeviceToken: "replacement-token", APNsEnvironment: "development",
			})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Direct construction has no configured attestor or state owner.
			s := &Server{}
			p := &registry.Provider{
				ID: "disabled-code-identity", APNsDeviceToken: "original-token",
				APNsEnvironment: "production", CodeAttested: true, FreshCodeAttested: true,
			}
			tc.run(s, p)
			p.Mu().Lock()
			defer p.Mu().Unlock()
			if p.APNsDeviceToken != "original-token" || p.APNsEnvironment != "production" ||
				!p.CodeAttested || !p.FreshCodeAttested {
				t.Fatalf("disabled code identity changed token/environment/proof flags: %+v", p)
			}
		})
	}
}
