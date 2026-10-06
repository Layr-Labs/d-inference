package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/reservation"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestParseReserveCommitMode(t *testing.T) {
	cases := map[string]struct {
		mode  reservation.CommitMode
		known bool
	}{
		"":         {reservation.Shared, true},
		"shared":   {reservation.Shared, true},
		"anything": {reservation.Shared, false}, // a typo falls back to shared AND is reported
		"global":   {reservation.Global, true},
		" GLOBAL ": {reservation.Global, true},
	}
	for raw, want := range cases {
		mode, known := reservation.ParseCommitMode(raw)
		if mode != want.mode || known != want.known {
			t.Errorf("parseReserveCommitMode(%q) = (%s, %v), want (%s, %v)", raw, mode, known, want.mode, want.known)
		}
	}
	t.Setenv(reservation.CommitModeEnv, "")
	reg, preparation := newReservationFixture()
	const model = "commit-mode-model"
	makeSchedulerProvider(t, reg, "commit-mode-provider", model, 100)
	// A shared commit must complete while another preparation retains its
	// registry read lease. A global commit would wait for Close below.
	held := preparation.planner.Prepare(model, &production.PendingRequest{RequestID: "held", Model: model})
	defer held.Close()
	done := make(chan *production.Provider, 1)
	go func() {
		p, _ := reg.ReserveProviderEx(model, &production.PendingRequest{RequestID: "default-mode", Model: model})
		done <- p
	}()
	select {
	case p := <-done:
		if p == nil {
			t.Fatal("default shared-mode reservation found no provider")
		}
		p.RemovePending("default-mode")
	case <-time.After(time.Second):
		held.Close()
		<-done
		t.Fatal("a registry built without EIGENINFERENCE_RESERVE_COMMIT_MODE must default to shared")
	}
}
