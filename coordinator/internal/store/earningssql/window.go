package earningssql

const (
	WindowIndex = "idx_provider_earnings_created_at_brin"
	// providerEarningsAnalyzeScaleFactor re-analyzes provider_earnings after
	// 0.5% of its rows change instead of the 10% default. At millions of
	// inserts/day the default lets the created_at histogram trail ingestion
	// by days, and the planner then costs a 24h
	// window as a few thousand rows.
	AnalyzeScaleFactor = "0.005"
)
