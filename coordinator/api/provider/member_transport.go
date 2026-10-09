package provider

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TrustedTLSProxies is the operator's statement that requests arriving from
// these immediate peers were TLS-terminated by a reverse proxy the operator
// controls. The zero value trusts none, which keeps the member transport rule
// at "the accepted request itself completed a TLS handshake".
//
// The coordinator cannot observe that handshake. It relies on three things the
// deployment must guarantee: only the proxy can reach the coordinator from a
// listed address, the proxy forwards only TLS traffic to it, and the proxy
// replaces any client-supplied X-Forwarded-Proto. Anything else able to connect
// from a listed address can claim TLS.
type TrustedTLSProxies struct {
	networks []netip.Prefix
}

// ParseTrustedTLSProxies reads a list of IP addresses or CIDR prefixes. An
// empty list is the disabled default; a malformed entry is an error, never a
// silently wider or narrower trust set.
func ParseTrustedTLSProxies(entries []string) (TrustedTLSProxies, error) {
	var trusted TrustedTLSProxies
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(entry)
		if err != nil {
			address, addressErr := netip.ParseAddr(entry)
			if addressErr != nil {
				return TrustedTLSProxies{}, fmt.Errorf("trusted TLS proxy %q is not an IP address or CIDR prefix", entry)
			}
			prefix = netip.PrefixFrom(address, address.BitLen())
		}
		if prefix.Bits() == 0 {
			return TrustedTLSProxies{}, fmt.Errorf("trusted TLS proxy %q would trust every peer", entry)
		}
		trusted.networks = append(trusted.networks, prefix.Masked())
	}
	return trusted, nil
}

// vouchesFor reports whether the request's immediate peer is a trusted proxy
// that marked the client connection as TLS. The peer address is the accepted
// socket's, never a forwarded header.
func (t TrustedTLSProxies) vouchesFor(r *http.Request) bool {
	if len(t.networks) == 0 {
		return false
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	peer = peer.Unmap()
	fromProxy := false
	for _, network := range t.networks {
		if network.Contains(peer) {
			fromProxy = true
			break
		}
	}
	if !fromProxy {
		return false
	}
	forwarded := r.Header.Values("X-Forwarded-Proto")
	return len(forwarded) == 1 && forwarded[0] == "https"
}

// memberTransport is the transport evidence for a member connection: the
// request's own TLS handshake, else the trusted-proxy policy, else none.
func (s *Owner) memberTransport(r *http.Request) registry.NativePairTransport {
	if r.TLS != nil {
		return registry.NativePairDirectTLS(r.TLS)
	}
	if s.trustedTLSProxies.vouchesFor(r) {
		return registry.NativePairTrustedProxyTLS()
	}
	return registry.NativePairTransport{}
}
