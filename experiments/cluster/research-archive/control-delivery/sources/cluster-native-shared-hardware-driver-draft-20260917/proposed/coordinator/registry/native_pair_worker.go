package registry

import (
	"bytes"
	"context"
	"crypto/sha256"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"time"
)

func nativePairWorkersReleased(starts [2]protocol.NativeAuthorizationStart) []byte {
	out := []byte("DBWA\x01")
	for _, start := range starts {
		b, _ := start.Canonical()
		h := sha256.Sum256(b)
		out = append(out, h[:]...)
	}
	return out
}

// Called only after actual Registry Released AND the original cancellation and
// relay-worker joins. Priority FIFO places this before any replacement prepare.
func (c *NativePairCoordinator) publishWorkersReleased(s *NativePairSession, frames [2][]byte) {
	var failed [2]bool
	for rank, payload := range frames {
		if !s.workerAttached[rank] {
			continue
		}
		p := s.connections[rank].provider
		if len(payload) == 0 || p.EnqueueText(context.Background(), payload) != nil {
			failed[rank] = true
			p.closeWriterNow()
		}
	}
	c.mu.Lock()
	for rank, bad := range failed {
		if bad {
			s.connections[rank].closed = true
		}
	}
	s.workerReleaseFailed = failed // retain the existing actual publication result
	s.workerReleasePublished = true
	c.removeReleasedLocked(s)
	close(s.workerReleaseDone)
	c.mu.Unlock()
}

// Same real committed pair, original connections/sequences, existing bounded
// writers and cleanup. This does not advertise solo or aggregate serving slots.
func (c *NativePairCoordinator) handleWorkerLocked(s *NativePairSession, rank int, kind string, payload []byte) error {
	if !s.committed || s.stopped || c.closed || c.revoked[s.approval.policy.ID] || !time.Now().Before(s.approval.policy.NotAfter) {
		return ErrNativePairControl
	}
	if _, e := c.registry.ValidateVerifiedPair(s.handle); e != nil {
		return e
	}
	common := s.starts[rank].Common
	if common.Schedule != 1 || common.MaximumTransportFrame != 131112 || common.MaximumPlaintext != 131072 || common.MaximumRecords != 1024 || common.MaximumCumulativePlaintext != 16777216 {
		return ErrNativePairControl
	}
	if kind == protocol.TypeNativePairWorkerAttach {
		b, _ := s.starts[rank].Canonical()
		h := sha256.Sum256(b)
		if s.workerAttached[rank] || !bytes.Equal(payload, append([]byte("DBWX\x01"), h[:]...)) {
			return ErrNativePairControl
		}
		s.workerAttached[rank] = true
		return nil
	}
	if !s.workerAttached[0] || !s.workerAttached[1] || !s.keyConfirmed[0] || !s.keyConfirmed[1] || s.meshRound != 4 {
		return ErrNativePairControl
	}
	binding, e := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
	if e != nil {
		return e
	}
	packet, e := protocol.DecodeNativePairWorkerPacket(payload, kind, sha256.Sum256(binding))
	if e != nil {
		return e
	}
	if s.workerRecords[rank] >= 128 || s.workerBytes[rank] > 2*1024*1024-uint64(len(payload)) {
		return ErrNativePairControl
	}
	switch kind {
	case protocol.TypeNativePairWorkerReady:
		if s.workerReady[rank] {
			return ErrNativePairControl
		}
		s.workerReady[rank] = true
		s.workerReadyPayload[rank] = append([]byte(nil), payload...)
		if s.workerReady[0] && s.workerReady[1] {
			if e = c.enqueueLocked(s, 0, protocol.TypeNativePairWorkerReady, s.workerReadyPayload[1]); e != nil {
				return e
			}
			s.workerReadyPayload = [2][]byte{}
		}
	case protocol.TypeNativePairWorkerCommand:
		if rank != 0 || !s.workerReady[0] || !s.workerReady[1] {
			return ErrNativePairControl
		}
		if !time.Now().Before(s.membership.ExpiresAt.Add(-time.Duration(packet.DeliverySlack))) {
			return ErrNativePairControl
		}
		if e = c.enqueueLocked(s, 1, kind, payload); e != nil {
			return e
		}
	case protocol.TypeNativePairWorkerEvent:
		if rank != 1 || !s.workerReady[0] || !s.workerReady[1] {
			return ErrNativePairControl
		}
		if e = c.enqueueLocked(s, 0, kind, payload); e != nil {
			return e
		}
	default:
		return ErrNativePairControl
	}
	s.workerRecords[rank]++
	s.workerBytes[rank] += uint64(len(payload))
	return nil
}
