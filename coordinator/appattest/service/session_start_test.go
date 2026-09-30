package service

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"testing/synctest"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type eventLog struct {
	mu     sync.Mutex
	events []map[string]any
}

func (l *eventLog) emit(fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, fields)
}

func (l *eventLog) outcomes() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, e := range l.events {
		out = append(out, e["stage"].(string)+":"+e["outcome"].(string))
	}
	return out
}

func TestStartSessionRunsExchangeForEnrolledCohort(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		server, client, closeAll := pipeWebSocket(t)
		defer closeAll()
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		r := registry.New(logger)
		endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
		p := r.Register("connected", server, &protocol.RegisterMessage{PublicKey: endpoint})
		defer r.Disconnect(p.ID)
		ctx, cancel := context.WithCancel(context.Background())
		log := &eventLog{}
		s := New(ctx, Config{Enabled: true, RolloutPercent: 100, AppID: "TEST.app", Environment: "production"},
			Dependencies{Store: store.NewMemory(store.Config{}), Registry: r, Logger: logger, Emit: log.emit})
		x := s.StartSession(ctx, p, &protocol.RegisterMessage{AppAttestProtocol: 3, Version: "0.9.4", Hardware: protocol.Hardware{ChipName: "Apple M4"}}, "account")
		if x == nil {
			t.Fatal("eligible provider got no session")
		}
		frame := (&attemptHarness{client: client}).read(t)
		if frame.Action != "prepare" || frame.Session != x.id || frame.ProtocolVersion != 3 {
			t.Fatalf("prepare frame %+v", frame)
		}
		machine := x.inventory.snapshot().ID
		want := sha256.Sum256([]byte("machine-owner-v1:account:" + machine))
		if machine == "" || x.owner != hex.EncodeToString(want[:]) {
			t.Fatal("session owner is not bound to the account and machine")
		}
		cancel()
		synctest.Wait()
		// Frames offered after the worker stops are counted, never queued.
		x.Offer(protocol.AppAttestShadowPayload{Session: x.id, Action: "ready", Result: "ok"})
		if !x.closed.Load() || x.dropped.Load() != 1 {
			t.Fatal("stopped session accepted a frame")
		}
		got := log.outcomes()
		for _, w := range []string{"registration:observed", "prepare:attempted", "ready:disconnected"} {
			if !contains(got, w) {
				t.Fatalf("missing %s in %v", w, got)
			}
		}
	})
}

func TestStartSessionOutsideCohortObservesWithoutChallenge(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		log := &eventLog{}
		s := New(ctx, Config{Enabled: true, RolloutPercent: 0, AppID: "TEST.app", Environment: "production"},
			Dependencies{Store: store.NewMemory(store.Config{}), Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Emit: log.emit})
		p := newSessionProvider(base64.StdEncoding.EncodeToString(make([]byte, 32)), "se")
		if x := s.StartSession(ctx, p, &protocol.RegisterMessage{AppAttestProtocol: 3}, "account"); x == nil {
			t.Fatal("session not created")
		}
		synctest.Wait()
		got := log.outcomes()
		if !contains(got, "registration:observed") || contains(got, "prepare:attempted") {
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
		cancel()
		synctest.Wait()
	})
}

func TestStartSessionRefusesUnservableRegistrations(t *testing.T) {
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	for _, tc := range []struct {
		name     string
		cfg      Config
		st       store.Store
		endpoint string
		protocol int
		want     string
	}{
		{"old protocol", Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, nil, endpoint, 2, "rollout:provider_upgrade_required"},
		{"unknown environment", Config{Enabled: true, AppID: "TEST.app", Environment: "staging"}, nil, endpoint, 3, "prepare:configuration_error"},
		{"missing app id", Config{Enabled: true, Environment: "production"}, nil, endpoint, 3, "prepare:configuration_error"},
		{"endpoint key with line break", Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, nil, endpoint[:20] + "\n" + endpoint[21:], 3, "prepare:encryption_key"},
		{"no shadow storage", Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, bareStore{}, endpoint, 3, "prepare:storage_unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			st := tc.st
			if st == nil {
				st = store.NewMemory(store.Config{})
			}
			log := &eventLog{}
			s := New(ctx, tc.cfg, Dependencies{Store: st, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Emit: log.emit})
			if x := s.StartSession(ctx, newSessionProvider(tc.endpoint, "se"), &protocol.RegisterMessage{AppAttestProtocol: tc.protocol}, "account"); x != nil {
				t.Fatal("unservable registration started an exchange")
			}
			if got := log.outcomes(); !contains(got, tc.want) {
				t.Fatalf("events %v, want %s", got, tc.want)
			}
		})
	}
}
