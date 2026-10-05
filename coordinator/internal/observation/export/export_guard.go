package export

import (
	profile "github.com/eigeninference/d-inference/coordinator/internal/observation/profile"
)

// guardCSVRow applies csvCell to every cell in place and returns the row.
func guardCSVRow(row []string) []string {
	for i := range row {
		row[i] = profile.CSVCell(row[i])
	}
	return row
}
