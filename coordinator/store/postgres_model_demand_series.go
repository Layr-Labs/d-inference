package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// All display widths aggregate the same privacy-qualified UTC hours. Suppressed
// hours cannot reappear in coarse intervals or the summaries derived from them.
func readModelDemandSeries(ctx context.Context, tx pgx.Tx, out *ModelDemandSnapshot, since, until time.Time, width time.Duration) error {
	rows, err := tx.Query(ctx, `WITH eligible_hours AS (
 SELECT model,hour,SUM(requests-excluded)::bigint AS requests,
 SUM(completed)::bigint AS completed,SUM(capacity_rejected)::bigint AS capacity_rejected,
 SUM(latency_rejected)::bigint AS latency_rejected,SUM(timed_out)::bigint AS timed_out,
 SUM(failed)::bigint AS failed,SUM(cancelled)::bigint AS cancelled,
 SUM(unknown)::bigint AS unknown,SUM(http_429)::bigint AS http_429
 FROM model_demand_hourly
 WHERE hour >= $1 AND hour < $2 AND requests>excluded
 GROUP BY model,hour
 HAVING SUM(requests-excluded)>=$4 AND COUNT(DISTINCT consumer_hash)>=$5
)
 SELECT model,date_bin($3 * interval '1 second',hour,$1) AS bucket,
 SUM(requests)::bigint,SUM(completed)::bigint,SUM(capacity_rejected)::bigint,
 SUM(latency_rejected)::bigint,SUM(timed_out)::bigint,SUM(failed)::bigint,
 SUM(cancelled)::bigint,SUM(unknown)::bigint,SUM(http_429)::bigint
 FROM eligible_hours
 GROUP BY model,bucket ORDER BY model,bucket`, since, until, int64(width/time.Second), ModelDemandMinRequests, ModelDemandMinConsumers)
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
		i := len(out.Models) - 1
		if i < 0 || out.Models[i].Model != model {
			out.Models = append(out.Models, ModelDemandCounts{Model: model, TimeSeries: emptyModelDemandSeries(since, until, width)})
			i++
		}
		out.Models[i].TimeSeries[int(at.Sub(since)/width)].Counts = &c
	}
	return rows.Err()
}
