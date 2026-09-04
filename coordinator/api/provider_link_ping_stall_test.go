package api

import (
	"context"
	"errors"
	"fmt"
	"net"
	"testing"
)

// TestIsLinkPingWriteStall pins the classifier on the exact error shapes
// nhooyr v1.8.17 produces: a ping that could not be WRITTEN (frame mutex not
// acquired within the 5 s control budget, or the socket the library closed
// under that budget) is a coordinator-side stall; a pong that never arrived
// is the peer's silence; a closed socket is someone else's verdict.
func TestIsLinkPingWriteStall(t *testing.T) {
	lockStall := fmt.Errorf("failed to ping: %w",
		fmt.Errorf("failed to write control frame %v: %w", "opPing",
			fmt.Errorf("failed to acquire lock: %w", context.DeadlineExceeded)))
	writeErr := fmt.Errorf("failed to ping: %w",
		fmt.Errorf("failed to write control frame %v: %w", "opPing",
			errors.New("failed to write frame: write tcp 127.0.0.1:1->127.0.0.1:2: i/o timeout")))
	pongWait := fmt.Errorf("failed to ping: %w",
		fmt.Errorf("failed to wait for pong: %w", context.DeadlineExceeded))
	for _, tc := range []struct {
		name string
		err  error
		want bool
	}{
		{"lock stall", lockStall, true},
		{"write error under the control budget", writeErr, true},
		{"pong wait timed out", pongWait, false},
		{"socket closed", fmt.Errorf("failed to ping: %w", net.ErrClosed), false},
		{"nil", nil, false},
	} {
		if got := isLinkPingWriteStall(tc.err); got != tc.want {
			t.Errorf("%s: isLinkPingWriteStall(%v) = %v, want %v", tc.name, tc.err, got, tc.want)
		}
	}
	// The pong-wait shape must still be a miss for the loop (it is what the
	// silent-peer tests rely on), and a write stall must not look like it.
	if errors.Is(pongWait, context.DeadlineExceeded) != true {
		t.Fatal("pong-wait error must unwrap to the ctx deadline")
	}
	if !errors.Is(lockStall, context.DeadlineExceeded) {
		t.Fatal("a lock stall also unwraps to a ctx deadline: the loop must classify by the write-control wrapper, not by errors.Is")
	}
}
