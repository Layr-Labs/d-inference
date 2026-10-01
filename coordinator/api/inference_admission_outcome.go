package api

import "net/http"

// admissionOutcome separates completed evaluation from terminal I/O. A handled
// outcome with no action has already been applied by a failed acquisition or
// fallback callback while the permit was released.
type admissionOutcome struct {
	model          string
	handled        bool
	applyRejection func()
}

func rejectedAdmission(model string, apply func()) admissionOutcome {
	return admissionOutcome{model: model, handled: true, applyRejection: apply}
}

// runInferenceAdmission shares preflight policy across both inference handlers.
// Every provider walk stays inside evaluation; its completed rejection applies
// refunds, store lookups, telemetry and HTTP output only after permit release.
func (s *Server) runInferenceAdmission(w http.ResponseWriter, r *http.Request, parsed map[string]any, p inferenceAdmissionParams) (string, bool) {
	permit := admissionScanPermit{server: s, w: w, r: r, parsed: parsed, params: p}
	defer permit.release()
	outcome := s.evaluateInferenceAdmission(w, r, parsed, p, &permit)
	permit.release()
	if outcome.applyRejection != nil {
		outcome.applyRejection()
	}
	return outcome.model, outcome.handled
}
