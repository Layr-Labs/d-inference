package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Snapshots serves GET /v1/admin/snapshots: fleet snapshot rows.
func (s *Controller) Snapshots(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	rows := filterSnapshotRows(s.store().FleetSnapshotsSince(parseSince(r)), q.Get("provider"), q.Get("model"))
	rows = capRecords(rows, parseLimit(r, defaultBrowseLimit))
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(rows),
		"data":   rows,
	})
}

// SnapshotsExport serves GET /v1/admin/snapshots/export as NDJSON.
func (s *Controller) SnapshotsExport(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	rows := filterSnapshotRows(s.store().FleetSnapshotsSince(parseSince(r)), q.Get("provider"), q.Get("model"))
	rows = capRecords(rows, parseLimit(r, 0))
	setExportHeaders(w, "snapshots", "ndjson")
	if err := writeNDJSON(w, rows); err != nil {
		s.logger().Error("admin snapshots ndjson export failed", "error", err)
	}
}

func filterSnapshotRows(in []store.FleetSnapshotRow, provider, model string) []store.FleetSnapshotRow {
	if provider == "" && model == "" {
		return in
	}
	out := make([]store.FleetSnapshotRow, 0, len(in))
	for _, row := range in {
		if provider != "" && row.ProviderID != provider {
			continue
		}
		if model != "" && row.Model != model {
			continue
		}
		out = append(out, row)
	}
	return out
}
