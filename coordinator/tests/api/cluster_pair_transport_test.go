package api_test

// A member may attach to pair control only over a protected transport. By
// default that is the accepted request's own TLS handshake. Behind a
// TLS-terminating reverse proxy the coordinator never sees one, so the
// operator can name the proxy's addresses; then a request from one of them
// that the proxy marked as HTTPS is accepted. These tests drive real sockets:
// the plain server's peer is 127.0.0.1, which stands in for the proxy.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/clustermember"
	"nhooyr.io/websocket"
)

func TestClusterMemberTransportBehindTrustedTLSProxy(t *testing.T) {
	https := http.Header{"X-Forwarded-Proto": {"https"}}
	cases := []struct {
		name     string
		trusted  []string
		tls      bool
		header   http.Header
		attaches bool
	}{
		// The setting is off: only a real handshake counts, whatever a header says.
		{name: "off, direct TLS", tls: true, attaches: true},
		{name: "off, plain with a forged header", header: https},
		// The setting is on for the loopback proxy.
		{name: "trusted proxy marks HTTPS", trusted: []string{"127.0.0.1/32", "::1"}, header: https, attaches: true},
		{name: "trusted proxy, no forwarded scheme", trusted: []string{"127.0.0.1"}},
		{name: "trusted proxy forwards plain HTTP", trusted: []string{"127.0.0.1"}, header: http.Header{"X-Forwarded-Proto": {"http"}}},
		{name: "trusted proxy, scheme list", trusted: []string{"127.0.0.1"}, header: http.Header{"X-Forwarded-Proto": {"https, http"}}},
		{name: "trusted proxy, repeated scheme header", trusted: []string{"127.0.0.1"}, header: http.Header{"X-Forwarded-Proto": {"https", "https"}}},
		// The peer is not the named proxy: its header is a client's claim.
		{name: "untrusted peer with the header", trusted: []string{"10.0.0.0/8"}, header: https},
		// Direct TLS keeps working when a proxy is also trusted.
		{name: "on, direct TLS without a header", trusted: []string{"10.0.0.0/8"}, tls: true, attaches: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := newPairDeployment(t, func(cfg *api.ServerConfig, catalogPath string) {
				cfg.ClusterPairs.CatalogPath = catalogPath
				cfg.ClusterPairs.TrustedTLSProxies = c.trusted
			})
			options := clustermember.Options{
				ServerURL: d.server.URL, HTTPClient: d.server.Client(), Header: c.header,
				AuthToken: "token-account-one", Serial: "serial-leader", ChipName: pairChip, Model: pairModel,
				Membership: &protocol.ClusterMembership{ClusterID: "studio-pair", Rank: 0, PolicySHA256: d.policy},
			}
			if !c.tls {
				plain := httptest.NewServer(d.fixture.Server.Handler())
				t.Cleanup(plain.Close)
				options.ServerURL, options.HTTPClient = plain.URL, nil
			}
			ctx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
			defer cancel()
			member := clustermember.Dial(t, ctx, options)
			providerID, refused, accepted := member.AwaitRegistration(ctx)
			if accepted != c.attaches {
				t.Fatalf("accepted=%v (close status %d), want attaches=%v", accepted, refused, c.attaches)
			}
			if !c.attaches {
				if refused != websocket.StatusPolicyViolation {
					t.Fatalf("refused transport closed with %d, want policy violation", refused)
				}
				return
			}
			// Attachment, not only acknowledgement: the member is listed for pairing.
			view := d.pair(t, "studio-pair")
			if !view.Members[0].Attached || view.Members[0].ProviderID != providerID {
				t.Fatalf("accepted member is not attached to pair control: %+v", view)
			}
		})
	}
}
