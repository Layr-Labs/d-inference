package shared

// SmallModelsInterestPageLimit bounds admin reads in both implementations,
// even when they are called without the HTTP layer.
func SmallModelsInterestPageLimit(limit int) int {
	if limit < 1 || limit > 100 {
		return 100
	}
	return limit
}
