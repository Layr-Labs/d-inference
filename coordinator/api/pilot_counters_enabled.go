//go:build pilotload

package api

import (
	"crypto/subtle"
	"net"
	"net/http"
	"os"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const pilotCounterPath = "/_pilot/counters"

type pilotPoolCounter interface {
	PilotPoolStats() (used, capacity int)
}

func (s *Server) registerPilotCounterRoutes() {
	token := os.Getenv("EIGENINFERENCE_PILOT_COUNTER_TOKEN")
	if len(token) < 32 {
		return
	}
	s.mux.HandleFunc("GET "+pilotCounterPath, func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "pilot counters require a loopback client", http.StatusForbidden)
			return
		}
		presented := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if len(presented) <= len(prefix) ||
			presented[:len(prefix)] != prefix ||
			subtle.ConstantTimeCompare([]byte(presented[len(prefix):]), []byte(token)) != 1 {
			http.Error(w, "pilot counter authorization required", http.StatusUnauthorized)
			return
		}

		mailboxUsed := s.registry.Queue().TotalSize()
		mailboxCapacity := s.registry.Queue().MaxSize()
		providerSessions := 0
		selfSignedSessions := 0
		hardwareSessions := 0
		for _, providerID := range s.registry.ProviderIDs() {
			if provider := s.registry.GetProvider(providerID); provider != nil {
				providerSessions++
				switch provider.GetTrustLevel() {
				case registry.TrustSelfSigned:
					selfSignedSessions++
				case registry.TrustHardware:
					hardwareSessions++
				}
				mailboxUsed += provider.PendingCount()
				mailboxCapacity += provider.MaxConcurrency()
			}
		}
		poolUsed, poolCapacity := 0, 0
		if counters, ok := s.store.(pilotPoolCounter); ok {
			poolUsed, poolCapacity = counters.PilotPoolStats()
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"pilot_counters": map[string]int{
				"mailbox_used":           mailboxUsed,
				"mailbox_capacity":       mailboxCapacity,
				"database_pool_used":     poolUsed,
				"database_pool_capacity": poolCapacity,
				"provider_sessions":      providerSessions,
				"protocol_v1_sessions":   providerSessions,
				"protocol_v2_sessions":   0,
				"untrusted_sessions":     providerSessions - selfSignedSessions - hardwareSessions,
				"self_signed_sessions":   selfSignedSessions,
				"hardware_sessions":      hardwareSessions,
			},
		})
	})
}
