package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"sort"
	"strconv"
	"time"
)

type networkModelEarning struct {
	ID       string `json:"id"`
	MicroUSD string `json:"earnings_micro_usd"`
}

func (s *Server) networkModelEarnings(now time.Time) any {
	reader, ok := store.As[store.NetworkModelEarningsReader](s.store)
	if !ok {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	since := now.Add(-7 * 24 * time.Hour)
	amounts, err := reader.NetworkModelEarnings(ctx, since, now)
	if err != nil {
		s.logger.Warn("network model earnings unavailable", "error", err)
		return nil
	}
	rows := make([]networkModelEarning, 0, len(amounts))
	for id, amount := range amounts {
		rows = append(rows, networkModelEarning{id, strconv.FormatInt(amount, 10)})
	}
	sort.Slice(rows, func(i, j int) bool {
		if amounts[rows[i].ID] != amounts[rows[j].ID] {
			return amounts[rows[i].ID] > amounts[rows[j].ID]
		}
		return rows[i].ID < rows[j].ID
	})
	return map[string]any{"window": "7d", "since": since, "as_of": now, "models": rows}
}
