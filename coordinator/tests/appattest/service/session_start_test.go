package service_test

import (
	"context"
	"encoding/base64"
	"slices"
	"strings"
	"testing"
	"testing/synctest"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

// bareStore exposes only the base Store interface, so optional App Attest
// capabilities are absent.
type bareStore struct{ store.Store }

func TestStartSessionRunsExchangeForEnrolledCohort(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		h := startExchange(t, exchangeOptions{})
		frame := h.read(t)
		if frame.Action != "prepare" || frame.Session == "" || frame.ProtocolVersion != 3 {
			t.Fatalf("prepare frame %+v", frame)
		}
		h.machineOwner(t)
		h.cancel()
		synctest.Wait()
		requireOutcomes(t, h.events.outcomes(), "registration:observed", "prepare:attempted", "ready:disconnected")
	})
}

func TestStartSessionOutsideCohortObservesWithoutChallenge(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		log := &eventLog{}
		st := &lifecycleInventoryStore{MemoryStore: memorystore.NewMemory(store.Config{}), observed: make(chan store.MachineObservation, 4)}
		s := service.New(ctx, service.Config{Enabled: true, RolloutPercent: 0, AppID: "TEST.app", Environment: "production"},
			service.Dependencies{Store: st, Logger: discardLogger(), Emit: log.emit})
		p := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
		x := s.StartSession(ctx, p, &protocol.RegisterMessage{AppAttestProtocol: 3}, "account")
		if x == nil {
			t.Fatal("session not created")
		}
		synctest.Wait()
		got := log.outcomes()
		if !slices.Contains(got, "registration:observed") || slices.Contains(got, "prepare:attempted") {
			t.Fatalf("events %v", got)
		}
		var rollout string
		for _, o := range got {
			if strings.HasPrefix(o, "rollout:") {
				rollout = o
			}
		}
		if rollout == "" || rollout == "rollout:enabled" {
			t.Fatalf("rollout decision not observed: %v", got)
		}

		// The worker has stopped while inventory keeps the connection open.
		// An oversized frame and a frame offered after the stop are both
		// evidence gaps; neither is queued.
		x.RejectOversized()
		x.Offer(protocol.AppAttestShadowPayload{Action: "ready", Result: "ok"})
		synctest.Wait()
		if after := log.outcomes(); len(after) != len(got) {
			t.Fatalf("stopped session handled a frame: %v", after)
		}
		cancel()
		synctest.Wait()
		if initial := <-st.observed; initial.Disconnected {
			t.Fatalf("initial observation %+v", initial)
		}
		if terminal := <-st.observed; !terminal.Disconnected || terminal.ShadowDropped != 2 {
			t.Fatalf("terminal observation %+v", terminal)
		}
	})
}

func TestStartSessionRefusesUnservableRegistrations(t *testing.T) {
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	for _, tc := range []struct {
		name     string
		cfg      service.Config
		st       store.Store
		endpoint string
		want     string
	}{
		{"unknown environment", service.Config{Enabled: true, AppID: "TEST.app", Environment: "staging"}, nil, endpoint, "prepare:configuration_error"},
		{"missing app id", service.Config{Enabled: true, Environment: "production"}, nil, endpoint, "prepare:configuration_error"},
		{"endpoint key with line break", service.Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, nil, endpoint[:20] + "\n" + endpoint[21:], "prepare:encryption_key"},
		{"no shadow storage", service.Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, bareStore{}, endpoint, "prepare:storage_unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			st := tc.st
			if st == nil {
				st = memorystore.NewMemory(store.Config{})
			}
			log := &eventLog{}
			s := service.New(ctx, tc.cfg, service.Dependencies{Store: st, Logger: discardLogger(), Emit: log.emit})
			if x := s.StartSession(ctx, newSessionProvider(tc.endpoint, "se"), &protocol.RegisterMessage{AppAttestProtocol: 3}, "account"); x != nil {
				t.Fatal("unservable registration started an exchange")
			}
			if got := log.outcomes(); !slices.Contains(got, tc.want) {
				t.Fatalf("events %v, want %s", got, tc.want)
			}
		})
	}
}
