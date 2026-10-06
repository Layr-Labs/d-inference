package registry_test

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	cachedemand "github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestConfigureCacheRoutingWarnsAboveSizingTTL(t *testing.T) {
	for _, tc := range []struct {
		name string
		mode string
		ttl  time.Duration
		warn bool
	}{
		{"sized", production.CacheRoutingOn, cachedemand.SizingTTL, false},
		{"default", production.CacheRoutingOn, 0, false},
		{"above", production.CacheRoutingOn, cachedemand.SizingTTL + time.Second, true},
		{"above_but_off", production.CacheRoutingOff, 2 * time.Hour, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var logs bytes.Buffer
			r := production.New(slog.New(slog.NewTextHandler(&logs, nil)))
			err := r.ConfigureCacheRouting(production.CacheRoutingConfig{
				Mode: tc.mode, ActivationPct: 100, TTL: tc.ttl,
				MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
			})
			if err != nil {
				t.Fatalf("a long ttl must not refuse to start: %v", err)
			}
			warned := strings.Contains(logs.String(), "level=WARN") &&
				strings.Contains(logs.String(), "cache routing ttl exceeds")
			if warned != tc.warn {
				t.Fatalf("warned=%v want %v: %s", warned, tc.warn, logs.String())
			}
			if tc.warn && (!strings.Contains(logs.String(), "sized_for="+cachedemand.SizingTTL.String()) ||
				!strings.Contains(logs.String(), fmt.Sprintf("demand_entries=%d", cachedemand.MaxEntries))) {
				t.Fatalf("warning lacks the sizing facts: %s", logs.String())
			}
			if want := tc.ttl; want != 0 && r.CacheRoutingConfigSnapshot().TTL != want {
				t.Fatalf("ttl=%s was not applied as configured", r.CacheRoutingConfigSnapshot().TTL)
			}
		})
	}
}
