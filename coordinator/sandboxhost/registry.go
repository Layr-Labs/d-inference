package sandboxhost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var (
	ErrSessionClosed   = errors.New("sandbox host session is closed")
	ErrSessionMismatch = errors.New("sandbox host session identity mismatch")
	ErrSequenceReplay  = errors.New("sandbox host sequence is not monotonic")
)

type Transport interface {
	Write(context.Context, []byte) error
	Close(string) error
}

type MessageHandler func(
	context.Context,
	*Session,
	protocol.SandboxDecodedMessage,
) error

type Registry struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	handler  MessageHandler
	now      func() time.Time
}

func NewRegistry(handler MessageHandler) *Registry {
	return &Registry{
		sessions: make(map[string]*Session),
		handler:  handler,
		now:      time.Now,
	}
}

type Session struct {
	registry  *Registry
	transport Transport

	mu              sync.RWMutex
	sendMu          sync.Mutex
	hostID          string
	connectionEpoch string
	capabilities    protocol.SandboxHostCapabilities
	lastInbound     uint64
	nextOutbound    uint64
	heartbeat       *protocol.SandboxHostHeartbeatPayload
	lastHeartbeat   time.Time
	closed          bool
}

type HostSnapshot struct {
	HostID          string
	ConnectionEpoch string
	Capabilities    protocol.SandboxHostCapabilities
	LastInbound     uint64
	NextOutbound    uint64
	Heartbeat       *protocol.SandboxHostHeartbeatPayload
	LastHeartbeat   time.Time
}

func (r *Registry) Register(
	header protocol.SandboxMessageHeader,
	payload *protocol.SandboxHostRegisterPayload,
	transport Transport,
) (*Session, error) {
	if payload == nil || transport == nil {
		return nil, errors.New("sandbox host registration is incomplete")
	}
	session := &Session{
		registry:        r,
		transport:       transport,
		hostID:          strings.ToLower(header.HostID),
		connectionEpoch: strings.ToLower(header.ConnectionEpoch),
		capabilities:    cloneCapabilities(payload.Capabilities),
		lastInbound:     header.Sequence,
		nextOutbound:    1,
	}

	r.mu.Lock()
	previous := r.sessions[session.hostID]
	r.sessions[session.hostID] = session
	r.mu.Unlock()

	if previous != nil {
		_ = previous.close("sandbox host reconnected")
	}
	return session, nil
}

func (r *Registry) Disconnect(session *Session) {
	if session == nil {
		return
	}
	session.mu.Lock()
	session.closed = true
	session.mu.Unlock()

	r.mu.Lock()
	if r.sessions[session.hostID] == session {
		delete(r.sessions, session.hostID)
	}
	r.mu.Unlock()
}

func (r *Registry) Session(hostID string) (*Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	session, ok := r.sessions[strings.ToLower(hostID)]
	return session, ok
}

func (r *Registry) Snapshots() []HostSnapshot {
	r.mu.RLock()
	sessions := make([]*Session, 0, len(r.sessions))
	for _, session := range r.sessions {
		sessions = append(sessions, session)
	}
	r.mu.RUnlock()

	snapshots := make([]HostSnapshot, 0, len(sessions))
	for _, session := range sessions {
		snapshots = append(snapshots, session.Snapshot())
	}
	return snapshots
}

func (s *Session) Handle(
	ctx context.Context,
	message protocol.SandboxDecodedMessage,
) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrSessionClosed
	}
	if !strings.EqualFold(message.Header.HostID, s.hostID) ||
		!strings.EqualFold(message.Header.ConnectionEpoch, s.connectionEpoch) {
		s.mu.Unlock()
		return ErrSessionMismatch
	}
	if message.Header.Sequence <= s.lastInbound {
		s.mu.Unlock()
		return ErrSequenceReplay
	}
	s.lastInbound = message.Header.Sequence
	if heartbeat, ok := message.Payload.(*protocol.SandboxHostHeartbeatPayload); ok {
		cloned := cloneHeartbeat(heartbeat)
		s.heartbeat = &cloned
		s.lastHeartbeat = s.registry.now().UTC()
	}
	s.mu.Unlock()

	if s.registry.handler != nil {
		return s.registry.handler(ctx, s, message)
	}
	return nil
}

func (s *Session) Send(
	ctx context.Context,
	messageType string,
	payload any,
) error {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrSessionClosed
	}
	sequence := s.nextOutbound
	s.nextOutbound++
	envelope := protocol.SandboxEnvelope[any]{
		Type:            messageType,
		ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID:          s.hostID,
		ConnectionEpoch: s.connectionEpoch,
		Sequence:        sequence,
		Payload:         payload,
	}
	s.mu.Unlock()

	encoded, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("encode sandbox host message: %w", err)
	}
	if err := s.transport.Write(ctx, encoded); err != nil {
		return fmt.Errorf("write sandbox host message: %w", err)
	}
	return nil
}

func (s *Session) Snapshot() HostSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var heartbeat *protocol.SandboxHostHeartbeatPayload
	if s.heartbeat != nil {
		cloned := cloneHeartbeat(s.heartbeat)
		heartbeat = &cloned
	}
	return HostSnapshot{
		HostID:          s.hostID,
		ConnectionEpoch: s.connectionEpoch,
		Capabilities:    cloneCapabilities(s.capabilities),
		LastInbound:     s.lastInbound,
		NextOutbound:    s.nextOutbound,
		Heartbeat:       heartbeat,
		LastHeartbeat:   s.lastHeartbeat,
	}
}

func (s *Session) HostID() string {
	return s.hostID
}

func (s *Session) close(reason string) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	s.mu.Unlock()
	return s.transport.Close(reason)
}

func cloneCapabilities(
	capabilities protocol.SandboxHostCapabilities,
) protocol.SandboxHostCapabilities {
	cloned := capabilities
	cloned.WorkspaceSizesBytes = append(
		[]uint64(nil),
		capabilities.WorkspaceSizesBytes...,
	)
	return cloned
}

func cloneHeartbeat(
	heartbeat *protocol.SandboxHostHeartbeatPayload,
) protocol.SandboxHostHeartbeatPayload {
	cloned := *heartbeat
	cloned.Leases = append(
		[]protocol.SandboxHostLeaseObservation(nil),
		heartbeat.Leases...,
	)
	return cloned
}
