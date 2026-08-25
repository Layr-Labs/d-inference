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
	ErrSessionClosed    = errors.New("sandbox host session is closed")
	ErrSessionMismatch  = errors.New("sandbox host session identity mismatch")
	ErrSequenceReplay   = errors.New("sandbox host sequence is not monotonic")
	ErrEpochReused      = errors.New("sandbox host connection epoch was reused")
	ErrInvalidHeartbeat = errors.New("sandbox host heartbeat exceeds registered capacity")
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
	epochs   map[string][]string
	handler  MessageHandler
	now      func() time.Time
}

func NewRegistry(handler MessageHandler) *Registry {
	return &Registry{
		sessions: make(map[string]*Session),
		epochs:   make(map[string][]string),
		handler:  handler,
		now:      time.Now,
	}
}

// SetHandler installs the durable control-plane result handler during server
// construction, before the registry is reachable by any WebSocket request.
func (r *Registry) SetHandler(handler MessageHandler) {
	r.mu.Lock()
	r.handler = handler
	r.mu.Unlock()
}

type Session struct {
	registry  *Registry
	transport Transport

	mu               sync.RWMutex
	sendMu           sync.Mutex
	hostID           string
	connectionEpoch  string
	capabilities     protocol.SandboxHostCapabilities
	lastInbound      uint64
	nextOutbound     uint64
	heartbeat        *protocol.SandboxHostHeartbeatPayload
	lastHeartbeat    time.Time
	closed           bool
	authorityContext context.Context
	cancelAuthority  context.CancelFunc
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
	hostID := strings.ToLower(header.HostID)
	connectionEpoch := strings.ToLower(header.ConnectionEpoch)
	authorityContext, cancelAuthority := context.WithCancel(context.Background())
	session := &Session{
		registry:         r,
		transport:        transport,
		hostID:           hostID,
		connectionEpoch:  connectionEpoch,
		capabilities:     cloneCapabilities(payload.Capabilities),
		lastInbound:      header.Sequence,
		nextOutbound:     1,
		authorityContext: authorityContext,
		cancelAuthority:  cancelAuthority,
	}

	r.mu.Lock()
	for _, previousEpoch := range r.epochs[hostID] {
		if previousEpoch == connectionEpoch {
			r.mu.Unlock()
			cancelAuthority()
			return nil, ErrEpochReused
		}
	}
	history := append(r.epochs[hostID], connectionEpoch)
	if len(history) > 64 {
		history = append([]string(nil), history[len(history)-64:]...)
	}
	r.epochs[hostID] = history
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
	session.cancelAuthority()
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
	if heartbeat, ok := message.Payload.(*protocol.SandboxHostHeartbeatPayload); ok {
		if !heartbeatMatchesCapabilities(heartbeat, s.capabilities) {
			s.mu.Unlock()
			return ErrInvalidHeartbeat
		}
		cloned := cloneHeartbeat(heartbeat)
		s.heartbeat = &cloned
		s.lastHeartbeat = s.registry.now().UTC()
	}
	s.lastInbound = message.Header.Sequence
	s.mu.Unlock()

	s.registry.mu.RLock()
	handler := s.registry.handler
	s.registry.mu.RUnlock()
	if handler != nil {
		handlerContext, cancel := context.WithCancel(ctx)
		stop := context.AfterFunc(s.authorityContext, cancel)
		defer func() {
			stop()
			cancel()
		}()
		if err := handler(handlerContext, s, message); err != nil {
			select {
			case <-s.authorityContext.Done():
				return ErrSessionClosed
			default:
				return err
			}
		}
		select {
		case <-s.authorityContext.Done():
			return ErrSessionClosed
		default:
		}
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
	s.cancelAuthority()
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

func heartbeatMatchesCapabilities(
	heartbeat *protocol.SandboxHostHeartbeatPayload,
	capabilities protocol.SandboxHostCapabilities,
) bool {
	if heartbeat == nil ||
		heartbeat.AvailableCPU > capabilities.CPUCount ||
		heartbeat.AvailableMemory > capabilities.MemoryBytes ||
		len(heartbeat.Leases) > int(capabilities.MaximumSandboxes) {
		return false
	}
	workspaceSizes := make(map[uint64]struct{}, len(capabilities.WorkspaceSizesBytes))
	for _, size := range capabilities.WorkspaceSizesBytes {
		workspaceSizes[size] = struct{}{}
	}
	seenSandboxes := make(map[string]struct{}, len(heartbeat.Leases))
	seenFences := make(map[uint64]struct{}, len(heartbeat.Leases))
	reservedCPU := uint64(0)
	reservedMemory := uint64(0)
	for _, lease := range heartbeat.Leases {
		if _, duplicate := seenSandboxes[lease.Scope.SandboxID]; duplicate {
			return false
		}
		if _, duplicate := seenFences[lease.Scope.FencingToken]; duplicate {
			return false
		}
		if _, supported := workspaceSizes[lease.Resources.WorkspaceBytes]; !supported ||
			(lease.Resources.GPU && !capabilities.SupportsGPU) ||
			lease.Scope.FencingToken >= heartbeat.NextFencingToken {
			return false
		}
		seenSandboxes[lease.Scope.SandboxID] = struct{}{}
		seenFences[lease.Scope.FencingToken] = struct{}{}
		reservedCPU += uint64(lease.Resources.CPUCount)
		memory, overflow := reservedMemory+lease.Resources.MemoryBytes,
			reservedMemory > ^uint64(0)-lease.Resources.MemoryBytes
		if overflow {
			return false
		}
		reservedMemory = memory
	}
	return reservedCPU+uint64(heartbeat.AvailableCPU) <=
		uint64(capabilities.CPUCount) &&
		reservedMemory <= capabilities.MemoryBytes-heartbeat.AvailableMemory
}
