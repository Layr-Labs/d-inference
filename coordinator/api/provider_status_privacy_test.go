package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestValidLoadModelStatusIsClosed(t *testing.T) {
	for _, status := range []string{
		protocol.LoadModelStatusStarted,
		protocol.LoadModelStatusSucceeded,
		protocol.LoadModelStatusFailed,
	} {
		if !validLoadModelStatus(status) {
			t.Fatalf("expected canonical status %q to be accepted", status)
		}
	}

	for _, status := range []string{
		"",
		"succeeded_PROMPT_LEAK_SENTINEL",
		"https://attacker.invalid/private",
	} {
		if validLoadModelStatus(status) {
			t.Fatalf("provider-controlled status %q was accepted", status)
		}
	}
}
