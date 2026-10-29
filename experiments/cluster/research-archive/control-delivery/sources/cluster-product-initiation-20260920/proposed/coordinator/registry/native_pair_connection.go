package registry

import (
	"bytes"
	"crypto/tls"
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The API passes r.TLS from its accepted request, not a forwarded header or a
// provider claim. Explicit trusted TLS proxy deployment support is separate.
// This is protocol attachment only, never native/runtime approval by itself.
func (c *NativePairCoordinator) Attach(p *Provider, nonce string, tlsState *tls.ConnectionState) (*NativePairConnection, error) {
	if c == nil || p == nil || tlsState == nil || !tlsState.HandshakeComplete {
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
	stopConfiguredIntent(n)
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
