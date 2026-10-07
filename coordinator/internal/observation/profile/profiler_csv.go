package profile

// csvCell neutralises spreadsheet formula injection: any cell that starts with
// a formula trigger is prefixed with a single quote so it renders as text.
func CSVCell(v string) string {
	if v == "" {
		return v
	}
	switch v[0] {
	case '=', '+', '-', '@', '\t', '\r':
		return "'" + v
	}
	return v
}
