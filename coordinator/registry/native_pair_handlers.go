package registry

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Handle is called by the real provider read loop with its retained attachment,
// never with a provider ID taken from the message. All peer bytes are public.
// A failure cancels the exact session; its active devices remain quarantined.
func (c *NativePairCoordinator) Handle(n *NativePairConnection, m *protocol.NativePairMessage) error {
	if c == nil {
		return ErrNativePairControl
	}
	c.mu.Lock()
	e := c.handleLocked(n, m)
	var s *NativePairSession
	if n != nil && n.coordinator == c {
		s = n.session
	}
	c.mu.Unlock()
	if s != nil && (e != nil || (m != nil && m.Type == protocol.TypeNativePairCancel)) {
		c.Cancel(s)
	}
	return e
}
func (c *NativePairCoordinator) handleLocked(n *NativePairConnection, m *protocol.NativePairMessage) error {
	if c.validConnectionLocked(n) && n.inboundSequence == math.MaxUint64 {
		n.closed = true
		return ErrNativePairControl
	}
	if !c.validConnectionLocked(n) || m == nil || !protocol.IsNativePairInbound(m.Type) || m.Validate() != nil || m.Signature == "" || m.PrepareBeforeUnixNano != 0 || m.ExpiresAtUnixNano != 0 || m.MemberNonce != n.nonce || n.inboundSequence == math.MaxUint64 || m.Sequence != n.inboundSequence+1 {
		return ErrNativePairControl
	}
	s := n.session
	if s == nil || c.sessions[s.membership.Epoch] != s || m.Epoch != hex.EncodeToString(s.membership.Epoch[:]) || m.Generation != s.membership.Generation {
		return ErrNativePairControl
	}
	rank := 0
	if s.connections[1] == n {
		rank = 1
	}
	if s.connections[rank] != n {
		return ErrNativePairControl
	}
	if !nativePairSignatureValid(s.membership.Members[rank].SEPublicKey, *m) {
		return ErrNativePairControl
	}
	payload, _ := m.PayloadBytes()
	// Even release/cancel must use the exact signed connection sequence. Release
	// remains possible after expiry, but only through the Registry's fresh trust
	// and original-identity checks plus a complete owner observation below.
	n.inboundSequence = m.Sequence
	if m.Type == protocol.TypeNativePairCancel {
		if !bytes.Equal(payload, []byte("DBNC\x01")) {
			return ErrNativePairControl
		}
		return nil
	}
	if m.Type == protocol.TypeNativePairOwnerReleased {
		if !s.committed || !bytes.Equal(payload, nativePairReleaseReceipt(s.starts[rank])) {
			return ErrNativePairControl
		}
		if e := c.registry.ObserveVerifiedPairOwnerReleased(s.handle, n.provider, s.membership.TranscriptSHA256); e != nil {
			return e
		}
		c.removeReleasedLocked(s)
		return nil
	}
	if s.stopped || c.closed || c.revoked[s.approval.policy.ID] || !time.Now().Before(s.approval.policy.NotAfter) {
		return ErrNativePairApproval
	}
	switch m.Type {
	case protocol.TypeNativePairPrepared:
		expected, _ := s.starts[rank].Canonical()
		if s.committed || !bytes.Equal(payload, expected) {
			return ErrNativePairControl
		}
		if e := c.registry.AcknowledgeVerifiedPairPrepared(s.handle, n.provider, s.membership.TranscriptSHA256); e != nil {
			return e
		}
		state, e := c.registry.VerifiedPairStatus(s.handle)
		if e != nil {
			return e
		}
		if state.Prepared[0] && state.Prepared[1] {
			if _, e = c.registry.CommitVerifiedPairOwners(s.handle); e != nil {
				return e
			}
			s.committed = true // No owner-start frame exists before the actual Commit.
			for r := range s.starts {
				b, _ := s.starts[r].Canonical()
				if e = c.enqueueLocked(s, r, protocol.TypeNativePairOwnerStart, b); e != nil {
					return e
				}
			}
		}
	case protocol.TypeNativePairHello:
		if !s.committed || s.hellos[rank] != nil {
			return ErrNativePairControl
		}
		if _, e := c.registry.ValidateVerifiedPair(s.handle); e != nil {
			return e
		}
		if protocol.ValidateNativeAuthorizationHello(payload, s.starts[rank]) != nil {
			return ErrNativePairControl
		}
		s.hellos[rank] = append([]byte(nil), payload...)
		if s.hellos[0] != nil && s.hellos[1] != nil {
			b, e := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
			if e != nil {
				return e
			}
			for r := range s.starts {
				if e = c.enqueueLocked(s, r, protocol.TypeNativePairBinding, b); e != nil {
					return e
				}
			}
		}
	case protocol.TypeNativePairConfirmation:
		if !s.committed || s.hellos[0] == nil || s.hellos[1] == nil || s.confirmations[rank] || len(payload) != 32 {
			return ErrNativePairControl
		}
		if _, e := c.registry.ValidateVerifiedPair(s.handle); e != nil {
			return e
		}
		// This relays the peer's signed MAC, not a claim that the coordinator verified
		// a secret it does not possess. The child must authenticate it in prelude A.
		s.confirmations[rank] = true
		if e := c.enqueueLocked(s, 1-rank, protocol.TypeNativePairPeerConfirmation, payload); e != nil {
			return e
		}
	default:
		return ErrNativePairControl
	}
	return nil
}
func nativePairSignatureValid(key string, m protocol.NativePairMessage) bool {
	encoded, e := base64.StdEncoding.DecodeString(key)
	if e != nil {
		return false
	}
	public, e := attestation.ParseP256PublicKey(encoded)
	if e != nil {
		return false
	}
	b, e := m.SigningBytes()
	if e != nil {
		return false
	}
	signature, e := base64.StdEncoding.DecodeString(m.Signature)
	if e != nil {
		return false
	}
	digest := sha256.Sum256(b)
	return ecdsa.VerifyASN1(public, digest[:], signature) // strict DER; no trailing data
}
func nativePairReleaseReceipt(start protocol.NativeAuthorizationStart) []byte {
	b, _ := start.Canonical()
	digest := sha256.Sum256(b)
	out := append([]byte("DBNR\x01"), digest[:]...)
	// native cleanup, authenticated owner lease-release ACK, actual owner transport
	// termination. A future member implementation may emit this only after all 3.
	return append(out, 1, 1, 1)
}
