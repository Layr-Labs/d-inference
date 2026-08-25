package api

import "net/http"

func (s *Server) requireSandboxAuth(
	next http.HandlerFunc,
) http.HandlerFunc {
	return s.requireAuth(func(w http.ResponseWriter, r *http.Request) {
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
		next(w, r)
	})
}
