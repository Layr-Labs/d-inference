package registry_test

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/connectiontime"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestConnectionOriginTime(t *testing.T) {
	var unknown *connectiontime.Origin
	if !unknown.Time().IsZero() || !connectiontime.New(time.Time{}).Time().IsZero() {
		t.Fatal("unknown origin must have zero creation time")
	}
	at := time.Date(2026, 10, 4, 12, 0, 0, 123, time.FixedZone("offset", 3600))
	if got := connectiontime.New(at).Time(); got != at {
		t.Fatalf("creation time = %v, want %v", got, at)
	}
}

func TestProviderRegisteredAtRemainsStable(t *testing.T) {
	var absent *production.Provider
	if !absent.RegisteredAt().IsZero() || !(&production.Provider{}).RegisteredAt().IsZero() {
		t.Fatal("provider without an origin must have zero registration time")
	}
	synctest.Test(t, func(t *testing.T) {
		r := production.New(testLogger())
		at := time.Now()
		p := r.Register("original", nil, &protocol.RegisterMessage{})
		time.Sleep(time.Minute)
		newer := r.Register("newer", nil, &protocol.RegisterMessage{})
		if got := p.RegisteredAt(); !got.Equal(at) || !got.Before(newer.RegisteredAt()) {
			t.Fatalf("registration time changed: original=%v newer=%v want=%v", got, newer.RegisteredAt(), at)
		}
		if duplicate := r.Register(p.ID, nil, &protocol.RegisterMessage{}); duplicate != p || !duplicate.RegisteredAt().Equal(at) {
			t.Fatal("duplicate registration replaced the original creation time")
		}
	})
}
