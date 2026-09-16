package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Routes serves GET /v1/admin/routes: a JSON page of routing
// decision records in the requested time window, with optional filtering by
// provider, model, and outcome.
func (s *Controller) Routes(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterRouteRecords(
		s.store().InferenceRouteRecordsSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("outcome"), q.Get("final_status"),
	)
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// RoutesExport serves GET /v1/admin/routes/export: a streamed CSV
// (default) or NDJSON download of routing decision records.
func (s *Controller) RoutesExport(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterRouteRecords(
		s.store().InferenceRouteRecordsSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("outcome"), q.Get("final_status"),
	)
	records = capRecords(records, parseLimit(r, 0))

	format := exportFormat(r)
	setExportHeaders(w, "routes", format)
	if format == "ndjson" {
		if err := writeNDJSON(w, records); err != nil {
			s.logger().Error("admin routes ndjson export failed", "error", err)
		}
		return
	}
	if err := writeRouteCSV(w, records); err != nil {
		s.logger().Error("admin routes csv export failed", "error", err)
	}
}

// filterRouteRecords applies the optional in-memory filters supported by the
// routes endpoints. Empty filter values are ignored. model matches either the
// concrete Model or the consumer-facing PublicModel.
func filterRouteRecords(in []store.InferenceRouteRecord, provider, model, outcome, finalStatus string) []store.InferenceRouteRecord {
	if provider == "" && model == "" && outcome == "" && finalStatus == "" {
		return in
	}
	out := make([]store.InferenceRouteRecord, 0, len(in))
	for _, rec := range in {
		if provider != "" && rec.ProviderID != provider {
			continue
		}
		if model != "" && rec.Model != model && rec.PublicModel != model {
			continue
		}
		if outcome != "" && rec.Outcome != outcome {
			continue
		}
		if finalStatus != "" && rec.FinalStatus != finalStatus {
			continue
		}
		out = append(out, rec)
	}
	return out
}
