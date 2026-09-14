package store

import (
	"context"
	"time"
)

const usageRecordColumns = `provider_id, consumer_key_hash, model, public_model, prompt_tokens,
	completion_tokens, created_at, request_id, cost_micro_usd, request_location`

// UsageRecords returns the most recent 10000 records, newest first.
func (s *PostgresStore) UsageRecords() []UsageRecord {
	return s.readUsageRecords(`SELECT ` + usageRecordColumns + ` FROM usage ORDER BY created_at DESC LIMIT 10000`)
}

// UsageRecordsSince returns records at or after since, oldest first.
func (s *PostgresStore) UsageRecordsSince(since time.Time) []UsageRecord {
	return s.readUsageRecords(`SELECT `+usageRecordColumns+`
		FROM usage WHERE ($1::timestamptz IS NULL OR created_at >= $1)
		ORDER BY created_at ASC`, nullSince(since))
}

// readUsageRecords preserves the historical read contract: query failures
// return nil, individual scan failures are skipped, and a successful empty
// query returns a non-nil slice. It does not reinterpret terminal rows.Err().
func (s *PostgresStore) readUsageRecords(query string, args ...any) []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	records := make([]UsageRecord, 0)
	for rows.Next() {
		var r UsageRecord
		var locationRaw []byte
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel,
			&r.PromptTokens, &r.CompletionTokens, &r.Timestamp, &r.RequestID,
			&r.CostMicroUSD, &locationRaw); err != nil {
			continue
		}
		r.CreatedAt = r.Timestamp
		r.RequestLocation = unmarshalProviderLocation(locationRaw)
		records = append(records, r)
	}
	return records
}
