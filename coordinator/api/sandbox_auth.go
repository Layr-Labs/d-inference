package api

import "net/http"

func (s *Server) requireSandboxAuth(
	next http.HandlerFunc,
) http.HandlerFunc {
	return s.requireAuth(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		kind, _ := r.Context().Value(ctxKeyCredentialKind).(credentialKind)
		if kind != credentialPrivy && kind != credentialAPIKey {
			writeJSON(
				w,
				http.StatusForbidden,
				errorResponse(
					"permission_error",
					"credential is not authorized for developer sandboxes",
				),
			)
			return
		}
		if !s.sandboxService.Enabled || s.sandboxes == nil {
			writeJSON(w, http.StatusServiceUnavailable,
				errorResponse("sandbox_unavailable", "sandbox service is disabled"))
			return
		}
		next(w, r)
	})
}

// Admission policy only gates work that consumes or extends capacity. Owners
// can still inspect, cancel, stop, and delete after removal from the allowlist.
func (s *Server) requireSandboxAdmission(next http.HandlerFunc) http.HandlerFunc {
	return s.requireSandboxAuth(func(w http.ResponseWriter, r *http.Request) {
		if !s.sandboxService.AdmissionEnabled {
			writeJSON(w, http.StatusServiceUnavailable,
				errorResponse("sandbox_draining", "sandbox admission is paused"))
			return
		}
		if !s.sandboxService.admits(consumerKeyFromContext(r.Context())) {
			writeJSON(w, http.StatusForbidden,
				errorResponse("sandbox_access_required", "account is not enrolled in the sandbox private alpha"))
			return
		}
		next(w, r)
	})
}
