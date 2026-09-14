package session

import (
	"errors"
	"io"
	"testing"

	"nhooyr.io/websocket"
)

func TestSessionDisconnectReason(t *testing.T) {
	tests := []struct {
		name         string
		closeStatus  websocket.StatusCode
		oomSuspected bool
		readReason   string
		want         string
	}{
		{"normal close frame", websocket.StatusNormalClosure, false, readErrorReasonGeneric, "ws_close_1000"},
		{"going away close frame", websocket.StatusGoingAway, false, readErrorReasonGeneric, "ws_close_1001"},
		{"policy violation (challenge force-reconnect)", websocket.StatusPolicyViolation, false, readErrorReasonGeneric, "ws_close_1008"},
		{"abrupt drop", -1, false, readErrorReasonGeneric, "read_error"},
		{"control-frame handling failure", -1, false, readErrorReasonControlFrame, "read_error_control_frame"},
		{"abrupt drop under memory pressure", -1, true, readErrorReasonGeneric, "oom_suspected"},
		// A close frame never coexists with the OOM classification in the read
		// loop (classification only runs on the abrupt branch), but the mapping
		// must still prioritize the stronger signal if both are ever set.
		{"oom wins over close frame", websocket.StatusNormalClosure, true, readErrorReasonGeneric, "oom_suspected"},
		// Likewise the read-error classification only exists on the frame-less
		// branch; a close code must win if both are ever set.
		{"close code wins over control-frame reason", websocket.StatusNormalClosure, false, readErrorReasonControlFrame, "ws_close_1000"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sessionDisconnectReason(tt.closeStatus, tt.oomSuspected, tt.readReason); got != tt.want {
				t.Errorf("sessionDisconnectReason(%d, %v, %q) = %q, want %q",
					tt.closeStatus, tt.oomSuspected, tt.readReason, got, tt.want)
			}
		})
	}
}

// TestReadErrorDisconnectReason pins the frame-less read-error classification.
// The first case is the exact chain nhooyr produces when a pong cannot take
// the write lock while a data frame is in flight (observed live in
// registry.TestUnfragmentedConnWriteStallsPeerPing); anything not about a
// control frame stays the generic "read_error".
func TestReadErrorDisconnectReason(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{"pong blocked behind an in-flight data frame",
			errors.New("failed to get reader: failed to handle control frame opPing: failed to write control frame opPong: failed to acquire lock: context deadline exceeded"),
			readErrorReasonControlFrame},
		{"pong write stalled on a full socket",
			errors.New("failed to get reader: failed to handle control frame opPing: failed to write control frame opPong: failed to write frame: context deadline exceeded"),
			readErrorReasonControlFrame},
		{"malformed control frame",
			errors.New("failed to get reader: failed to handle control frame opPing: received fragmented control frame"),
			readErrorReasonControlFrame},
		{"tcp reset",
			errors.New("failed to get reader: failed to read frame header: read tcp 127.0.0.1:1->127.0.0.1:2: read: connection reset by peer"),
			readErrorReasonGeneric},
		{"eof", io.EOF, readErrorReasonGeneric},
		{"nil", nil, readErrorReasonGeneric},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := readErrorDisconnectReason(tt.err); got != tt.want {
				t.Errorf("readErrorDisconnectReason(%v) = %q, want %q", tt.err, got, tt.want)
			}
		})
	}
}
