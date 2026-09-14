package operations

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

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
