// Admin read + download endpoints for routing telemetry.
//
// These handlers expose the coordinator's routing-decision and rejection
// telemetry for offline analysis and calibration. They are admin-gated and
// metadata-only: no prompt or response content is recorded or exported, so
// every column is safe to download in bulk. See
// docs/design/routing-telemetry-and-calibration.md.

package observation

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	routeexport "github.com/eigeninference/d-inference/coordinator/internal/observation/export"
)

// defaultBrowseLimit caps how many records the JSON browse handlers return when
// the caller does not pass an explicit ?limit=. Exports are uncapped by default.
const defaultBrowseLimit = 1000

// --- Handlers -------------------------------------------------------------

// HandleAdminRoutes serves GET /v1/admin/routes: a JSON page of routing
// decision records in the requested time window, with optional filtering by
// provider, model, and outcome.
func (s *Owner) HandleAdminRoutes(w http.ResponseWriter, r *http.Request) {
	if !s.hooks.RequireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := routeexport.FilterRoutes(
		s.store.InferenceRouteRecordsSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("outcome"), q.Get("final_status"),
	)
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// HandleAdminRoutesExport serves GET /v1/admin/routes/export: a streamed CSV
// (default) or NDJSON download of routing decision records.
func (s *Owner) HandleAdminRoutesExport(w http.ResponseWriter, r *http.Request) {
	if !s.hooks.RequireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := routeexport.FilterRoutes(
		s.store.InferenceRouteRecordsSince(parseSince(r)),
		q.Get("provider"), q.Get("model"), q.Get("outcome"), q.Get("final_status"),
	)
	records = capRecords(records, parseLimit(r, 0))

	format := exportFormat(r)
	setExportHeaders(w, "routes", format)
	if format == "ndjson" {
		if err := writeNDJSON(w, records); err != nil {
			s.logger.Error("admin routes ndjson export failed", "error", err)
		}
		return
	}
	if err := routeexport.WriteRouteCSV(w, records); err != nil {
		s.logger.Error("admin routes csv export failed", "error", err)
	}
}

// HandleAdminRejections serves GET /v1/admin/rejections: a JSON page of
// rejected-request records in the requested time window, with optional
// filtering by reason, model, and could_have_served.
func (s *Owner) HandleAdminRejections(w http.ResponseWriter, r *http.Request) {
	if !s.hooks.RequireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := routeexport.FilterRejections(
		s.store.RejectionRecordsSince(parseSince(r)),
		q.Get("reason"), q.Get("model"), q.Get("could_have_served"),
	)
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// HandleAdminRejectionsExport serves GET /v1/admin/rejections/export: a streamed
// CSV (default) or NDJSON download of rejected-request records.
func (s *Owner) HandleAdminRejectionsExport(w http.ResponseWriter, r *http.Request) {
	if !s.hooks.RequireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	records := routeexport.FilterRejections(
		s.store.RejectionRecordsSince(parseSince(r)),
		q.Get("reason"), q.Get("model"), q.Get("could_have_served"),
	)
	records = capRecords(records, parseLimit(r, 0))

	format := exportFormat(r)
	setExportHeaders(w, "rejections", format)
	if format == "ndjson" {
		if err := writeNDJSON(w, records); err != nil {
			s.logger.Error("admin rejections ndjson export failed", "error", err)
		}
		return
	}
	if err := routeexport.WriteRejectionCSV(w, records); err != nil {
		s.logger.Error("admin rejections csv export failed", "error", err)
	}
}

// --- Request parsing helpers ---------------------------------------------

// parseSince resolves the ?since= query parameter to an absolute lower-bound
// timestamp. It accepts either a Go duration relative to now (e.g. "24h",
// "168h") or an RFC3339 timestamp. When absent or unparseable it defaults to
// the last 24 hours.
func parseSince(r *http.Request) time.Time {
	raw := strings.TrimSpace(r.URL.Query().Get("since"))
	if raw != "" {
		if d, err := time.ParseDuration(raw); err == nil {
			if d < 0 {
				d = -d
			}
			return time.Now().Add(-d)
		}
		if t, err := time.Parse(time.RFC3339, raw); err == nil {
			return t
		}
	}
	return time.Now().Add(-24 * time.Hour)
}

// maxBrowseLimit bounds the caller-supplied ?limit= so a single browse response
// can't be asked to materialize an unreasonable number of rows. It matches the
// store-side read cap; the store never returns more than that regardless.
const maxBrowseLimit = 50000

// parseLimit reads ?limit= as a non-negative row cap, clamped to maxBrowseLimit.
// A missing or invalid value falls back to def; a value of 0 (or def == 0) means
// "no in-memory cap" (the store still hard-caps the underlying read).
func parseLimit(r *http.Request, def int) int {
	raw := strings.TrimSpace(r.URL.Query().Get("limit"))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return def
	}
	if n > maxBrowseLimit {
		return maxBrowseLimit
	}
	return n
}

// exportFormat returns the normalized ?format= value: "ndjson" when explicitly
// requested, otherwise "csv" (the default).
func exportFormat(r *http.Request) string {
	if strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("format")), "ndjson") {
		return "ndjson"
	}
	return "csv"
}

// setExportHeaders sets the download Content-Type and a timestamped attachment
// filename for the given base name ("routes"/"rejections") and format.
func setExportHeaders(w http.ResponseWriter, base, format string) {
	ext, ctype := "csv", "text/csv"
	if format == "ndjson" {
		ext, ctype = "ndjson", "application/x-ndjson"
	}
	filename := base + "-" + time.Now().UTC().Format(time.RFC3339) + "." + ext
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Content-Disposition", "attachment; filename="+strconv.Quote(filename))
}

// capRecords truncates in to at most limit rows. limit <= 0 means no cap.
func capRecords[T any](in []T, limit int) []T {
	if limit > 0 && len(in) > limit {
		return in[:limit]
	}
	return in
}

// --- Filters --------------------------------------------------------------

// --- NDJSON ---------------------------------------------------------------

// writeNDJSON encodes one JSON object per line. json.Encoder.Encode appends a
// newline after each value, yielding newline-delimited JSON, and streams each
// record straight to w.
func writeNDJSON[T any](w http.ResponseWriter, records []T) error {
	enc := json.NewEncoder(w)
	for i := range records {
		if err := enc.Encode(records[i]); err != nil {
			return err
		}
	}
	return nil
}

// --- CSV ------------------------------------------------------------------

// --- scalar formatting ----------------------------------------------------
