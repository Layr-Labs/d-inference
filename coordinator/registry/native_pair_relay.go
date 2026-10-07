package registry

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (c *NativePairCoordinator) messageLocked(s *NativePairSession, rank int, kind string, payload []byte) ([]byte, error) {
	n := s.connections[rank]
	if n.outboundSequence == math.MaxUint64 {
		n.closed = true
		return nil, ErrNativePairControl
	}
	m := protocol.NativePairMessage{Type: kind, Version: 1, MemberNonce: n.nonce, Epoch: hex.EncodeToString(s.membership.Epoch[:]), Generation: s.membership.Generation, Sequence: n.outboundSequence + 1, Payload: base64.StdEncoding.EncodeToString(payload), PrepareBeforeUnixNano: s.membership.PrepareBefore.UnixNano(), ExpiresAtUnixNano: s.membership.ExpiresAt.UnixNano()}
	if m.Validate() != nil {
		return nil, ErrNativePairControl
	}
	b, e := json.Marshal(m)
	if e != nil || len(b) > protocol.NativePairFrameLimit {
		return nil, ErrNativePairControl
	}
	n.outboundSequence++
	return b, nil
}
func (c *NativePairCoordinator) enqueueLocked(s *NativePairSession, rank int, kind string, payload []byte) error {
	if s.stopped || s.queuedFrames[rank] >= nativePairQueueFrames || s.queuedBytes[rank] > nativePairQueueBytes-protocol.NativePairFrameLimit {
		return ErrNativePairControl
	}
	b, e := c.messageLocked(s, rank, kind, payload)
	if e != nil {
		return e
	}
	select {
	case s.queues[rank] <- b:
		s.queuedBytes[rank] += len(b)
		s.queuedFrames[rank]++
		return nil
	default:
		return ErrNativePairControl
	}
}
func (c *NativePairCoordinator) writeLoop(s *NativePairSession, rank int) {
	defer s.workers.Done()
	for {
		select {
		case <-s.ctx.Done():
			return
		case b := <-s.queues[rank]:
			c.mu.Lock()
			valid := !s.stopped && !c.closed && !c.revoked[s.approval.policy.ID] && time.Now().Before(s.approval.policy.NotAfter) && c.validConnectionLocked(s.connections[rank])
			if valid {
				if s.committed {
					_, e := c.registry.ValidateVerifiedPair(s.handle)
					valid = e == nil
				} else {
					status, e := c.registry.VerifiedPairStatus(s.handle)
					valid = e == nil && status.Phase == VerifiedPairPending && time.Now().Before(status.Membership.PrepareBefore)
				}
			}
			c.mu.Unlock()
			if !valid {
				c.Cancel(s)
				return
			}
			// The fixed membership deadline is unchanged; the five-second cap bounds
			// one control write. Cancellation interrupts this through the real writer.
			deadline := time.Now().Add(5 * time.Second)
			if s.membership.ExpiresAt.Before(deadline) {
				deadline = s.membership.ExpiresAt
			}
			ctx, cancel := context.WithDeadline(s.ctx, deadline)
			e := s.connections[rank].provider.WriteTextControl(ctx, b)
			cancel()
			c.mu.Lock()
			s.queuedBytes[rank] -= len(b)
			s.queuedFrames[rank]--
			c.mu.Unlock()
			if e != nil {
				c.Cancel(s)
				return
			}
		}
	}
}

// Cancel first closes real Registry admission. It reserves a separate tiny
// priority cancel record rather than waiting for the bounded public relay.
// Cancelling an in-flight real writer may close the socket: that is another
// stop signal, NEVER a cleanup receipt. No unbounded per-frame goroutines.
func (c *NativePairCoordinator) Cancel(s *NativePairSession) {
	if c == nil || s == nil {
		return
	}
	c.mu.Lock()
	frames, publish := c.beginCancellationLocked(s)
	c.mu.Unlock()
	if publish {
		c.publishCancellation(s, frames)
	}
}

// The caller holds mu. Claim exactly one terminal publication obligation before
// Registry Done can wake the worker-join observer. Stopped workers alone do not
// allow these connections to be reused until that obligation is completed.
func (c *NativePairCoordinator) beginCancellationLocked(s *NativePairSession) ([2][]byte, bool) {
	if s.coordinator != c || c.sessions[s.membership.Epoch] != s || s.stopped {
		return [2][]byte{}, false
	}
	s.stopped = true
	_ = c.registry.CancelVerifiedPair(s.handle)
	var frames [2][]byte
	for rank := range frames {
		frames[rank], _ = c.messageLocked(s, rank, protocol.TypeNativePairCancel, []byte("DBNC\x01"))
	}
	return frames, true
}

// The caller owns the once-only obligation returned by beginCancellationLocked.
// No coordinator lock is held across actual writer enqueue or close attempts.
func (c *NativePairCoordinator) publishCancellation(s *NativePairSession, frames [2][]byte) {
	for rank, payload := range frames {
		p := s.connections[rank].provider
		if len(payload) == 0 || p.EnqueueText(context.Background(), payload) != nil {
			p.closeWriterNow()
		}
	}
	// This cannot wait behind WriteTextControl. If its bytes were already in
	// flight, provider_writer closes that socket to interrupt them.
	s.stop()
	c.mu.Lock()
	s.cancellationPublished = true
	c.removeReleasedLocked(s)
	c.mu.Unlock()
}
func (c *NativePairCoordinator) finishWriters(s *NativePairSession) {
	s.workers.Wait()
	c.mu.Lock()
	defer c.mu.Unlock()
	s.writersEnded = true
	close(s.writersStopped)
	for rank := range s.queues {
	drain:
		for {
			select {
			case <-s.queues[rank]:
			default:
				break drain
			}
		}
		s.queuedBytes[rank] = 0
		s.queuedFrames[rank] = 0
	}
	c.removeReleasedLocked(s)
}
func (c *NativePairCoordinator) removeReleasedLocked(s *NativePairSession) {
	if !s.writersEnded || !s.cancellationPublished {
		return
	}
	c.registry.mu.RLock()
	released := s.handle.registry == c.registry && s.handle.state != nil && s.handle.state.phase == VerifiedPairReleased
	c.registry.mu.RUnlock()
	if !released {
		return
	} // Only the actual Registry phase proves its hold ended.
	if c.sessions[s.membership.Epoch] == s {
		delete(c.sessions, s.membership.Epoch)
	}
	for _, n := range s.connections {
		if n.session == s {
			n.session = nil
		}
	}
}
func (c *NativePairCoordinator) RevokeApproval(id string) {
	if c == nil {
		return
	}
	c.mu.Lock()
	if _, ok := c.catalog.entries[id]; !ok {
		c.mu.Unlock()
		return
	}
	c.revoked[id] = true
	var list []*NativePairSession
	for _, s := range c.sessions {
		if s.approval.policy.ID == id {
			list = append(list, s)
		}
	}
	c.mu.Unlock()
	for _, s := range list {
		c.Cancel(s)
	}
}
func (c *NativePairCoordinator) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.closed = true
	var list []*NativePairSession
	for _, s := range c.sessions {
		list = append(list, s)
	}
	c.mu.Unlock()
	for _, s := range list {
		c.Cancel(s)
	}
}
