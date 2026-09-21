package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestConsoleKeyInheritsSelfRouteOnly(t *testing.T) {
	now := time.Date(2026, 9, 16, 18, 0, 0, 0, time.UTC)
	past := now.Add(-time.Hour)
	future := now.Add(time.Hour)

	self := store.APIKey{SelfRouteOnly: true}
	open := store.APIKey{SelfRouteOnly: false}
	disabledOpen := store.APIKey{SelfRouteOnly: false, Disabled: true}
	expiredOpen := store.APIKey{SelfRouteOnly: false, ExpiresAt: &past}
	futureOpen := store.APIKey{SelfRouteOnly: false, ExpiresAt: &future}
	disabledSelf := store.APIKey{SelfRouteOnly: true, Disabled: true}

	cases := []struct {
		name string
		keys []store.APIKey
		want bool
	}{
		{name: "no keys", keys: nil, want: false},
		{name: "one machine-only", keys: []store.APIKey{self}, want: true},
		{name: "two machine-only", keys: []store.APIKey{self, self}, want: true},
		{name: "machine-only and unrestricted", keys: []store.APIKey{self, open}, want: false},
		{name: "only unrestricted", keys: []store.APIKey{open}, want: false},
		{name: "machine-only plus disabled unrestricted", keys: []store.APIKey{self, disabledOpen}, want: true},
		{name: "machine-only plus expired unrestricted", keys: []store.APIKey{self, expiredOpen}, want: true},
		{name: "machine-only plus unexpired unrestricted", keys: []store.APIKey{self, futureOpen}, want: false},
		{name: "only disabled machine-only", keys: []store.APIKey{disabledSelf}, want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := consoleKeyInheritsSelfRouteOnly(tc.keys, now)
			if got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}
