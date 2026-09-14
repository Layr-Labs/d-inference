package operations

import (
	"strconv"
	"time"
)

func csvInt(v int) string { return strconv.Itoa(v) }

func csvI64(v int64) string { return strconv.FormatInt(v, 10) }

func csvFloat(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

func csvBool(v bool) string { return strconv.FormatBool(v) }

func csvTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format(time.RFC3339)
}

// An empty CSV cell, like JSON null and SQL NULL, denotes unknown servability.
func csvOptionalBool(value *bool) string {
	if value == nil {
		return ""
	}
	return csvBool(*value)
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
