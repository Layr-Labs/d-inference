package readiness

import (
	"net/http"
	"time"
)

// coordinatorDrainRetryAfter is the Retry-After advertised to inference requests
// rejected by the drain gate. Kept small so well-behaved clients retry quickly
// against the next ready coordinator instead of failing hard.
const coordinatorDrainRetryAfter = 3 * time.Second

// Gate counts requests before checking drain and trust safety. Mount it outside
// authentication and decryption on every inference route. Rejected requests back
// out their count; admitted requests remain counted until the handler returns.
func (s *Controller) Gate(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Count this request as in-flight BEFORE reading the drain flag. If we
		// checked draining first and incremented second, a request entering in the
		// window between a concurrent SetDraining(true) and its own increment could
		// slip past the gate while /readyz still reported inflight:0 — telling the
		// deploy script it was safe to kill the process mid-request. Incrementing
		// first makes Inflight() (and thus /readyz) a strict upper bound on requests
		// past the gate: any request that observes draining==false was already
		// counted, so it can never be running while /readyz reports 0.
		s.incInflight()
		if s.IsDraining() {
			// Lost the race (or drain was already set): back the count out and
			// reject. A rejected request nets zero change to Inflight().
			s.decInflight()
			s.deps.WriteRateLimited(w, "coordinator", "draining", coordinatorDrainRetryAfter)
			return
		}
		if blocked, reason := s.deps.TrustSafetyStatus(); blocked {
			s.decInflight()
			s.deps.WriteRateLimited(w, "coordinator", reason, coordinatorDrainRetryAfter)
			return
		}
		defer s.decInflight()
		next(w, r)
	}
}
