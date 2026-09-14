package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Profiles serves GET /v1/admin/profiles: a JSON page of profile
// records in the requested window, filterable by provider, model, final_status.
func (s *Controller) Profiles(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	// Predicates go to the store so the read cap applies AFTER filtering.
	records := s.store().RequestProfilesSinceFiltered(parseSince(r), store.RequestProfileFilter{
		ProviderID: q.Get("provider"), Model: q.Get("model"),
		FinalStatus: q.Get("final_status"), CoordRequestID: q.Get("coord_request_id"),
	})
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// ProfilesExport serves GET /v1/admin/profiles/export as NDJSON.
func (s *Controller) ProfilesExport(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	// Predicates go to the store so the read cap applies AFTER filtering.
	records := s.store().RequestProfilesSinceFiltered(parseSince(r), store.RequestProfileFilter{
		ProviderID: q.Get("provider"), Model: q.Get("model"),
		FinalStatus: q.Get("final_status"), CoordRequestID: q.Get("coord_request_id"),
	})
	records = capRecords(records, parseLimit(r, 0))
	setExportHeaders(w, "profiles", "ndjson")
	if err := writeNDJSON(w, records); err != nil {
		s.logger().Error("admin profiles ndjson export failed", "error", err)
	}
}
