package registry

import (
	"bytes"
	"crypto/tls"
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// NativePairTransport is the API's evidence that a member connection is
// protected in transit. The zero value is unprotected and never attaches.
type NativePairTransport struct {
	direct       *tls.ConnectionState
	trustedProxy bool
}

// NativePairDirectTLS is the handshake state of the accepted request itself
// (r.TLS), never a forwarded header or a provider claim.
func NativePairDirectTLS(state *tls.ConnectionState) NativePairTransport {
	return NativePairTransport{direct: state}
}

// NativePairTrustedProxyTLS records that the operator's explicitly configured
// TLS-terminating proxy delivered the request. The coordinator did not observe
// the handshake; only the API's trusted-proxy policy may construct this.
func NativePairTrustedProxyTLS() NativePairTransport {
	return NativePairTransport{trustedProxy: true}
}

func (t NativePairTransport) protected() bool {
	return t.trustedProxy || (t.direct != nil && t.direct.HandshakeComplete)
}

// This is protocol attachment only, never native/runtime approval by itself.
func (c *NativePairCoordinator) Attach(p *Provider, nonce string, transport NativePairTransport) (*NativePairConnection, error) {
	if c == nil || p == nil || !transport.protected() {
		return nil, ErrNativePairControl
	}
	b, e := hex.DecodeString(nonce)
	if e != nil || len(b) != 32 || hex.EncodeToString(b) != nonce || bytes.Equal(b, make([]byte, 32)) {
		return nil, ErrNativePairControl
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.connections[p] != nil {
		return nil, ErrNativePairControl
	}
	c.registry.mu.RLock()
	p.mu.Lock()
	valid := p.registry == c.registry && c.registry.providers[p.ID] == p && p.executionRole == protocol.ExecutionRoleClusterMember && p.memberNonce == nonce
	p.mu.Unlock()
	c.registry.mu.RUnlock()
	if !valid {
		return nil, ErrNativePairControl
	}
	n := &NativePairConnection{coordinator: c, provider: p, nonce: nonce}
	c.connections[p] = n
	c.wakeFormation()
	return n, nil
}
func (c *NativePairCoordinator) Detach(n *NativePairConnection) {
	if c == nil || n == nil {
		return
	}
	c.mu.Lock()
	if n.coordinator != c || c.connections[n.provider] != n {
		c.mu.Unlock()
		return
	}
	n.closed = true
	delete(c.connections, n.provider)
	s := n.session
	c.mu.Unlock()
	if s != nil {
		c.Cancel(s)
	}
}
func (c *NativePairCoordinator) validConnectionLocked(n *NativePairConnection) bool {
	return n != nil && n.coordinator == c && !n.closed && c.connections[n.provider] == n
}

// The coordinator's selector passes exact current Provider objects; no provider
// can initiate a grant by naming an arbitrary peer or submitting policy hashes.
func (c *NativePairCoordinator) Connections(m [2]*Provider) ([2]*NativePairConnection, error) {
	var result [2]*NativePairConnection
	if c == nil {
		return result, ErrNativePairControl
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, p := range m {
		result[i] = c.connections[p]
		if !c.validConnectionLocked(result[i]) {
			return [2]*NativePairConnection{}, ErrNativePairControl
		}
	}
	return result, nil
}
