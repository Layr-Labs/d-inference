package registry

import (
	"bytes"
	"crypto/sha256"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Called only under c.mu, after Handle has authenticated the exact original
// connection and consumed its signed sequence. Reuses the real active grant and
// existing bounded writers; a failure takes Handle's ordinary cancellation path.
func (c *NativePairCoordinator) handleMeshLocked(s *NativePairSession, rank int, kind string, payload []byte) error {
	if !s.committed || !s.confirmations[0] || !s.confirmations[1] {
		return ErrNativePairControl
	}
	if _, e := c.registry.ValidateVerifiedPair(s.handle); e != nil {
		return e
	}
	binding, e := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
	if e != nil {
		return e
	}
	digest := sha256.Sum256(binding)
	if kind == protocol.TypeNativePairKeyConfirmed {
		if s.keyConfirmed[rank] || !bytes.Equal(payload, protocol.NativePairKeyConfirmed(digest)) {
			return ErrNativePairControl
		}
		s.keyConfirmed[rank] = true
		if s.keyConfirmed[0] && s.keyConfirmed[1] {
			// Reports mean both children authenticated their peer MAC. The
			// coordinator only authenticates their providers and exact transcript.
			for r := range s.connections {
				if e := c.enqueueLocked(s, r, protocol.TypeNativePairMeshReady, payload); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if kind != protocol.TypeNativePairMesh || !s.keyConfirmed[0] || !s.keyConfirmed[1] || s.meshRound >= 4 || s.meshPending[rank] != nil {
		return ErrNativePairControl
	}
	value, e := protocol.DecodeNativePairMeshPacket(payload, digest, uint8(rank), s.meshRound, false)
	if e != nil {
		return e
	}
	s.meshPending[rank] = value
	if s.meshPending[0] == nil || s.meshPending[1] == nil {
		return nil
	}
	gathered := append(append([]byte(nil), s.meshPending[0]...), s.meshPending[1]...)
	for r := range s.connections {
		packet, e := protocol.NativePairMeshPacket(digest, uint8(r), s.meshRound, gathered, true)
		if e != nil {
			return e
		}
		if e = c.enqueueLocked(s, r, protocol.TypeNativePairMeshReply, packet); e != nil {
			return e
		}
	}
	// FIFO writers preserve round order even if a faster peer advances while
	// the other reply remains in flight. There is at most one contribution/rank.
	s.meshPending = [2][]byte{}
	s.meshRound++
	return nil
}
