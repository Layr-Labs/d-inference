package cacheattempt

import (
	"testing"
	"time"
)

type receiptCallbacks struct {
	forget   func(string)
	terminal func(string, time.Time)
}

func (r receiptCallbacks) ForgetCacheAttempt(nonce string) {
	r.forget(nonce)
}

func (r receiptCallbacks) MarkCacheAttemptTerminal(nonce string, now time.Time) {
	r.terminal(nonce, now)
}

// Directory cleanup may itself coordinate request metadata. It must observe
// the completed transition and be able to acquire the preparation lock.
func TestStateReceiptCleanupRunsAfterPreparationUnlock(t *testing.T) {
	for _, transition := range []string{"replace", "terminal"} {
		t.Run(transition, func(t *testing.T) {
			var state State
			ticket, open := state.Begin(nil)
			if !open {
				t.Fatal("new state is closed")
			}
			now := time.Unix(42, 0)
			calls := 0
			check := func(nonce string) {
				calls++
				if nonce != "original-nonce" {
					t.Errorf("cleanup targeted %q", nonce)
				}
				state.PublishLegacy(ticket, func() {
					t.Error("cleanup observed the retired preparation as current")
				})
			}
			receipts := receiptCallbacks{
				forget: func(nonce string) {
					if transition != "replace" {
						t.Error("terminal forgot its receipt grace")
					}
					check(nonce)
				},
				terminal: func(nonce string, got time.Time) {
					if transition != "terminal" || !got.Equal(now) {
						t.Errorf("wrong terminal cleanup: transition=%s time=%v", transition, got)
					}
					check(nonce)
				},
			}
			if !state.Publish(ticket, New(&Generation{}, receipts, Metadata{Nonce: "original-nonce"})) {
				t.Fatal("initial publication failed")
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				if transition == "replace" {
					state.Begin(nil)
				} else {
					state.Terminal(now)
				}
			}()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("receipt cleanup could not reenter preparation after transition")
			}
			if calls != 1 {
				t.Fatalf("cleanup called %d times, want once", calls)
			}
		})
	}
}

func TestStateLegacyPublicationStaysWithItsPreparation(t *testing.T) {
	for _, transition := range []string{"unchanged", "replacement", "terminal"} {
		t.Run(transition, func(t *testing.T) {
			var state State
			key := "left-over"
			reset := func() { key = "" }
			ticket, open := state.Begin(reset)
			if !open || key != "" {
				t.Fatal("preparation did not clear old legacy metadata")
			}
			switch transition {
			case "replacement":
				next, _ := state.Begin(reset)
				state.PublishLegacy(next, func() { key = "replacement" })
			case "terminal":
				state.Terminal(time.Now())
			}
			state.PublishLegacy(ticket, func() { key = "original" })
			want := map[string]string{"unchanged": "original", "replacement": "replacement", "terminal": ""}[transition]
			if key != want {
				t.Fatalf("legacy key = %q, want %q", key, want)
			}
			_, open = state.Begin(reset)
			if key != "" || open != (transition != "terminal") {
				t.Fatalf("next preparation: key=%q open=%v", key, open)
			}
		})
	}
}
