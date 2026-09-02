package api

// Admin read + export endpoints for the system profiler tables. Admin-gated,
// metadata-only (no prompt or response content is ever persisted), JSON browse
// or NDJSON export. CSV is deliberately not offered for these tables: the rows
// carry nested JSON columns that do not flatten well, and NDJSON is what the
// routingsim loaders consume.

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleAdminProfiles serves GET /v1/admin/profiles: a JSON page of profile
// records in the requested window, filterable by provider, model, final_status.
func (s *Server) handleAdminProfiles(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterProfileRecords(
		s.store.RequestProfilesSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("final_status"), q.Get("coord_request_id"),
	)
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// handleAdminProfilesExport serves GET /v1/admin/profiles/export as NDJSON.
func (s *Server) handleAdminProfilesExport(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterProfileRecords(
		s.store.RequestProfilesSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("final_status"), q.Get("coord_request_id"),
	)
	records = capRecords(records, parseLimit(r, 0))
	setExportHeaders(w, "profiles", "ndjson")
	if err := writeNDJSON(w, records); err != nil {
		s.logger.Error("admin profiles ndjson export failed", "error", err)
	}
}

// handleAdminSnapshots serves GET /v1/admin/snapshots: fleet snapshot rows.
func (s *Server) handleAdminSnapshots(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	rows := filterSnapshotRows(s.store.FleetSnapshotsSince(parseSince(r)), q.Get("provider"), q.Get("model"))
	rows = capRecords(rows, parseLimit(r, defaultBrowseLimit))
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(rows),
		"data":   rows,
	})
}

// handleAdminSnapshotsExport serves GET /v1/admin/snapshots/export as NDJSON.
func (s *Server) handleAdminSnapshotsExport(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	rows := filterSnapshotRows(s.store.FleetSnapshotsSince(parseSince(r)), q.Get("provider"), q.Get("model"))
	rows = capRecords(rows, parseLimit(r, 0))
	setExportHeaders(w, "snapshots", "ndjson")
	if err := writeNDJSON(w, rows); err != nil {
		s.logger.Error("admin snapshots ndjson export failed", "error", err)
	}
}

func filterProfileRecords(in []store.RequestProfileRecord, provider, model, finalStatus, coordID string) []store.RequestProfileRecord {
	if provider == "" && model == "" && finalStatus == "" && coordID == "" {
		return in
	}
	out := make([]store.RequestProfileRecord, 0, len(in))
	for _, rec := range in {
		if provider != "" && rec.ProviderID != provider {
			continue
		}
		if model != "" && rec.Model != model && rec.PublicModel != model {
			continue
		}
		if finalStatus != "" && rec.FinalStatus != finalStatus {
			continue
		}
		if coordID != "" && rec.CoordRequestID != coordID {
			continue
		}
		out = append(out, rec)
	}
	return out
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

// csvCell neutralises spreadsheet formula injection: any cell that starts with
// a formula trigger is prefixed with a single quote so it renders as text.
func csvCell(v string) string {
	if v == "" {
		return v
	}
	switch v[0] {
	case '=', '+', '-', '@', '\t', '\r':
		return "'" + v
	}
	return v
}

// guardCSVRow applies csvCell to every cell in place and returns the row.
func guardCSVRow(row []string) []string {
	for i := range row {
		row[i] = csvCell(row[i])
	}
	return row
}
