package api

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	sandboxHostRegistrationTimeout = 10 * time.Second
	sandboxHostWriteTimeout        = 5 * time.Second
	sandboxHostReadIdleTimeout     = 60 * time.Second
	sandboxHostFrameLimit          = 2 * 1024 * 1024
)

func (s *Server) handleSandboxHostWS(w http.ResponseWriter, r *http.Request) {
	if s.sandboxHostAuth == nil || !s.sandboxHostAuth.Enabled() {
		http.Error(w, "sandbox host service unavailable", http.StatusServiceUnavailable)
		return
	}
	hostID, token, ok := sandboxHostCredentials(r)
	if !ok || !s.sandboxHostAuth.Authenticate(hostID, token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	connection, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		s.logger.Warn("sandbox host websocket accept failed", "error", err)
		return
	}
	connection.SetReadLimit(sandboxHostFrameLimit)
	transport := &sandboxWebSocketTransport{connection: connection}

	registrationContext, cancelRegistration := context.WithTimeout(
		r.Context(),
		sandboxHostRegistrationTimeout,
	)
	messageType, encoded, err := connection.Read(registrationContext)
	cancelRegistration()
	if err != nil {
		_ = connection.Close(websocket.StatusPolicyViolation, "registration required")
		return
	}
	if messageType != websocket.MessageText {
		_ = connection.Close(websocket.StatusUnsupportedData, "text frames required")
		return
	}
	message, err := protocol.DecodeSandboxHostMessage(encoded)
	if err != nil ||
		message.Header.Type != protocol.SandboxTypeHostRegister ||
		!strings.EqualFold(message.Header.HostID, hostID) {
		_ = connection.Close(websocket.StatusPolicyViolation, "invalid registration")
		return
	}
	registration, ok := message.Payload.(*protocol.SandboxHostRegisterPayload)
	if !ok {
		_ = connection.Close(websocket.StatusPolicyViolation, "invalid registration")
		return
	}
	session, err := s.sandboxHosts.Register(
		message.Header,
		registration,
		transport,
	)
	if err != nil {
		status := websocket.StatusInternalError
		if errors.Is(err, sandboxhost.ErrEpochReused) {
			status = websocket.StatusPolicyViolation
		}
		_ = connection.Close(status, "registration failed")
		return
	}
	defer func() {
		s.sandboxHosts.Disconnect(session)
		_ = connection.Close(websocket.StatusNormalClosure, "goodbye")
	}()

	s.logger.Info(
		"sandbox host connected",
		"host_id",
		session.HostID(),
		"remote",
		r.RemoteAddr,
	)
	heartbeatDeadline := time.Now().Add(sandboxHostReadIdleTimeout)
	for {
		readContext, cancelRead := context.WithDeadline(
			r.Context(),
			heartbeatDeadline,
		)
		messageType, encoded, err = connection.Read(readContext)
		cancelRead()
		if err != nil {
			return
		}
		if messageType != websocket.MessageText {
			_ = connection.Close(
				websocket.StatusUnsupportedData,
				"text frames required",
			)
			return
		}
		message, err = protocol.DecodeSandboxHostMessage(encoded)
		if err != nil {
			_ = connection.Close(
				websocket.StatusPolicyViolation,
				"invalid sandbox host frame",
			)
			return
		}
		if message.Header.Type == protocol.SandboxTypeHostRegister {
			_ = connection.Close(
				websocket.StatusPolicyViolation,
				"duplicate registration",
			)
			return
		}
		handleErr := session.Handle(r.Context(), message)
		if message.Header.Type == protocol.SandboxTypeHostHeartbeat {
			heartbeatDeadline = session.Snapshot().LastHeartbeat.Add(
				sandboxHostReadIdleTimeout,
			)
		}
		if handleErr != nil {
			if sandboxHostResultConflict(handleErr) {
				s.logger.Warn(
					"ignored stale sandbox host result",
					"host_id",
					session.HostID(),
					"message_type",
					message.Header.Type,
					"error",
					handleErr,
				)
				continue
			}
			status := websocket.StatusPolicyViolation
			if errors.Is(handleErr, sandboxhost.ErrSessionClosed) {
				status = websocket.StatusNormalClosure
			} else if !errors.Is(handleErr, sandboxhost.ErrSequenceReplay) &&
				!errors.Is(handleErr, sandboxhost.ErrSessionMismatch) {
				status = websocket.StatusInternalError
			}
			_ = connection.Close(status, "sandbox host frame rejected")
			return
		}
	}
}

func sandboxHostResultConflict(err error) bool {
	return errors.Is(err, store.ErrNotFound) ||
		errors.Is(err, store.ErrSandboxConflict) ||
		errors.Is(err, store.ErrSandboxInvalidTransition)
}

func sandboxHostCredentials(r *http.Request) (string, string, bool) {
	hostValues := r.Header.Values(sandboxhost.HostIDHeader)
	authorizationValues := r.Header.Values("Authorization")
	if len(hostValues) != 1 ||
		len(authorizationValues) != 1 ||
		!sandboxhost.CanonicalHostID(hostValues[0]) {
		return "", "", false
	}
	authorization := authorizationValues[0]
	if len(authorization) < len("Bearer ")+1 ||
		!strings.EqualFold(authorization[:len("Bearer")], "Bearer") ||
		authorization[len("Bearer")] != ' ' {
		return "", "", false
	}
	token := authorization[len("Bearer "):]
	if token == "" || strings.TrimSpace(token) != token ||
		strings.ContainsAny(token, " \t\r\n") {
		return "", "", false
	}
	return hostValues[0], token, true
}

type sandboxWebSocketTransport struct {
	connection *websocket.Conn
}

func (t *sandboxWebSocketTransport) Write(
	ctx context.Context,
	encoded []byte,
) error {
	writeContext, cancel := context.WithTimeout(ctx, sandboxHostWriteTimeout)
	defer cancel()
	return t.connection.Write(writeContext, websocket.MessageText, encoded)
}

func (t *sandboxWebSocketTransport) Close(reason string) error {
	return t.connection.Close(websocket.StatusNormalClosure, reason)
}
