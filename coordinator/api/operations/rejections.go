package operations

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Rejections serves GET /v1/admin/rejections: a JSON page of
// rejected-request records in the requested time window, with optional
// filtering by reason, model, and could_have_served.
func (s *Controller) Rejections(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterRejectionRecords(
		s.store().RejectionRecordsSince(parseSince(r)),
		q.Get("reason"), q.Get("model"), q.Get("could_have_served"),
	)
	records = capRecords(records, parseLimit(r, defaultBrowseLimit))
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"count":  len(records),
		"data":   records,
	})
}

// RejectionsExport serves GET /v1/admin/rejections/export: a streamed
// CSV (default) or NDJSON download of rejected-request records.
func (s *Controller) RejectionsExport(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	q := r.URL.Query()
	records := filterRejectionRecords(
		s.store().RejectionRecordsSince(parseSince(r)),
		q.Get("reason"), q.Get("model"), q.Get("could_have_served"),
	)
	records = capRecords(records, parseLimit(r, 0))

	format := exportFormat(r)
	setExportHeaders(w, "rejections", format)
	if format == "ndjson" {
		if err := writeNDJSON(w, records); err != nil {
			s.logger().Error("admin rejections ndjson export failed", "error", err)
		}
		return
	}
	if err := writeRejectionCSV(w, records); err != nil {
		s.logger().Error("admin rejections csv export failed", "error", err)
	}
}

// filterRejectionRecords applies the optional in-memory filters supported by the
// rejections endpoints. Empty filter values are ignored. model matches either
// RequestedModel or ResolvedModel; couldHaveServed filters on the boolean only
// when it is exactly "true" or "false".
func filterRejectionRecords(in []store.RejectionRecord, reason, model, couldHaveServed string) []store.RejectionRecord {
	var wantServed *bool
	switch strings.ToLower(strings.TrimSpace(couldHaveServed)) {
	case "true":
		v := true
		wantServed = &v
	case "false":
		v := false
		wantServed = &v
	}
	if reason == "" && model == "" && wantServed == nil {
		return in
	}
	out := make([]store.RejectionRecord, 0, len(in))
	for _, rec := range in {
		if reason != "" && rec.ReasonCode != reason {
			continue
		}
		if model != "" && rec.RequestedModel != model && rec.ResolvedModel != model {
			continue
		}
		if wantServed != nil && (rec.CouldHaveServed == nil || *rec.CouldHaveServed != *wantServed) {
			continue
		}
		out = append(out, rec)
	}
	return out
}
