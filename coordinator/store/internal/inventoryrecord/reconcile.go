package inventoryrecord

func ReconcileLimit(limit int) int {
	if limit < 1 || limit > 100 {
		return 100
	}
	return limit
}
