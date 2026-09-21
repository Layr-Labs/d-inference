package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Only already-publishable models are queried. Each interval independently
// passes the privacy floor; totals may exceed the sum of visible intervals.
func readModelDemandSeries(ctx context.Context, tx pgx.Tx, out *ModelDemandSnapshot, since, until time.Time, width time.Duration) error {
	if len(out.Models) == 0 {
		return nil
	}
	ids := make([]string, 0, len(out.Models))
	byModel := map[string]int{}
	for i := range out.Models {
		m := &out.Models[i]
		ids = append(ids, m.Model)
		byModel[m.Model] = i
		m.TimeSeries = emptyModelDemandSeries(since, until, width)
	}
	rows, err := tx.Query(ctx, `SELECT model,date_bin($3 * interval '1 second',hour,$1) AS bucket,
 SUM(requests-excluded)::bigint,SUM(completed)::bigint,SUM(capacity_rejected)::bigint,
 SUM(latency_rejected)::bigint,SUM(timed_out)::bigint,SUM(failed)::bigint,
 SUM(cancelled)::bigint,SUM(unknown)::bigint,SUM(http_429)::bigint
 FROM model_demand_hourly
 WHERE hour >= $1 AND hour < $2 AND model=ANY($4) AND requests>excluded
 GROUP BY model,bucket HAVING SUM(requests-excluded)>=$5 AND COUNT(DISTINCT consumer_hash)>=$6
 ORDER BY model,bucket`, since, until, int64(width/time.Second), ids, ModelDemandMinRequests, ModelDemandMinConsumers)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var model string
		var at time.Time
		var c DemandOutcomeCounts
		if err := rows.Scan(&model, &at, &c.Requests, &c.Completed, &c.CapacityRejected, &c.LatencyRejected, &c.TimedOut, &c.Failed, &c.Cancelled, &c.Unknown, &c.HTTP429); err != nil {
			return err
		}
		if i, ok := byModel[model]; ok {
			index := int(at.Sub(since) / width)
			if index >= 0 && index < len(out.Models[i].TimeSeries) {
				out.Models[i].TimeSeries[index].Counts = &c
			}
		}
	}
	return rows.Err()
}
