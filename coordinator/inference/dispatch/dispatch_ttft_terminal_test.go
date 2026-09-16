package dispatch

import (
	"testing"
)

// TestTTFTTerminalRejectKillSwitch pins the env wiring: default ON, only an
// explicit falsey value restores the legacy attempt-0-only behavior.
func TestTTFTTerminalRejectKillSwitch(t *testing.T) {
	t.Setenv(envTTFTTerminalReject, "")
	if !ttftTerminalRejectEnabled() {
		t.Fatal("terminal TTFT rejection must default to enabled")
	}
	t.Setenv(envTTFTTerminalReject, "false")
	if ttftTerminalRejectEnabled() {
		t.Fatal("EIGENINFERENCE_TTFT_TERMINAL_REJECT=false must disable the terminal rejection")
	}
	t.Setenv(envTTFTTerminalReject, "true")
	if !ttftTerminalRejectEnabled() {
		t.Fatal("EIGENINFERENCE_TTFT_TERMINAL_REJECT=true must enable the terminal rejection")
	}
}
