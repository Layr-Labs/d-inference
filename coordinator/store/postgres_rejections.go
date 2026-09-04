package store

// request_rejections WRITE path for PostgresStore: the single-row insert and
// the multi-row batch share one column list, one bind-argument builder and one
// statement builder, so the two cannot drift. The reader
// (RejectionRecordsSince) stays in postgres.go.
//
// The batch exists for the telemetry sink (api/telemetry_sink_batch.go): a
// rate-limit or drain storm produces one rejection row per 429, and writing
// them one statement each on the single sink worker let a throttled client
// fill the queue and drop other consumers' route rows. One INSERT per group
// keeps the worker ahead of any storm the request path can generate.

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// rejectionInsertColumns is the ordered insert column list.
// rejectionInsertArgs MUST append values in exactly this order.
const rejectionInsertColumns = `request_id, endpoint, stage, reason_code, http_status, consumer_key_hash, key_id, client_class,
			requested_model, resolved_model, stream, n, estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_image, has_audio, has_tools, tool_count, response_format, self_route_only, prefer_owner,
			params, request_body_bytes, retry_after_ms,
			could_have_served, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections,
			warm_provider_existed, best_ttft_ms, shortfall_micro_usd, limit_kind, over_by,
			created_at`

// rejectionInsertParamCount is the number of bind parameters per row — the
// length of rejectionInsertColumns.
const rejectionInsertParamCount = 36

// maxRejectionInsertRows caps the rows in one multi-row INSERT (36 x 256 =
// 9,216 bind parameters, far below PostgreSQL's 65,535 ceiling). Larger
// batches are written as several statements.
const maxRejectionInsertRows = 256

const (
	rejectionWriteTimeout      = 5 * time.Second
	rejectionBatchWriteTimeout = 10 * time.Second
)

// rejectionInsertSQL builds INSERT INTO request_rejections (...) VALUES
// ($1..$36), ($37..$72), ... for rows records. rows == 1 is the historical
// single-row statement.
func rejectionInsertSQL(rows int) string {
	var b strings.Builder
	b.Grow(len(rejectionInsertColumns) + rows*rejectionInsertParamCount*6 + 64)
	b.WriteString("INSERT INTO request_rejections (\n\t\t\t")
	b.WriteString(rejectionInsertColumns)
	b.WriteString("\n\t\t) VALUES ")
	param := 1
	for r := 0; r < rows; r++ {
		if r > 0 {
			b.WriteString(",\n\t\t")
		}
		b.WriteByte('(')
		for c := 0; c < rejectionInsertParamCount; c++ {
			if c > 0 {
				b.WriteString(", ")
			}
			b.WriteByte('$')
			b.WriteString(strconv.Itoa(param))
			param++
		}
		b.WriteByte(')')
	}
	return b.String()
}

// rejectionInsertArgs appends record's bind values to dst in
// rejectionInsertColumns order. A zero CreatedAt defaults to now; empty
// Params is passed as nil (SQL NULL) so an invalid empty JSONB value is never
// written (mirrors marshalProviderLocation).
func rejectionInsertArgs(dst []any, record *RejectionRecord, now time.Time) []any {
	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = now
	}
	var params json.RawMessage
	if len(record.Params) > 0 {
		params = record.Params
	}
	return append(dst,
		record.RequestID, record.Endpoint, record.Stage, record.ReasonCode, record.HTTPStatus, record.ConsumerKeyHash, record.KeyID, record.ClientClass,
		record.RequestedModel, record.ResolvedModel, record.Stream, record.N, record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasImage, record.HasAudio, record.HasTools, record.ToolCount, record.ResponseFormat, record.SelfRouteOnly, record.PreferOwner,
		params, record.RequestBodyBytes, record.RetryAfterMs,
		record.CouldHaveServed, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections,
		record.WarmProviderExisted, record.BestTTFTMs, record.ShortfallMicroUSD, record.LimitKind, record.OverBy,
		createdAt,
	)
}

// execRejectionInsert issues one multi-row insert for rows (non-empty).
func (s *PostgresStore) execRejectionInsert(rows []*RejectionRecord, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	args := make([]any, 0, len(rows)*rejectionInsertParamCount)
	for _, r := range rows {
		args = rejectionInsertArgs(args, r, time.Now().UTC())
	}
	_, err := s.pool.Exec(ctx, rejectionInsertSQL(len(rows)), args...)
	return err
}

// RecordRejections writes many rejection records as one multi-row INSERT per
// chunk of maxRejectionInsertRows (nil records skipped). Each chunk is a
// single statement and therefore atomic; a failure stops at the failing chunk
// and is returned so the sink's failure policy can replay rows individually
// or drop and count.
func (s *PostgresStore) RecordRejections(records []*RejectionRecord) error {
	for _, chunk := range splitRejectionBatches(records, maxRejectionInsertRows) {
		if err := s.execRejectionInsert(chunk, rejectionBatchWriteTimeout); err != nil {
			return fmt.Errorf("store: record rejections (%d rows): %w", len(chunk), err)
		}
	}
	return nil
}

// splitRejectionBatches drops nil records and chunks the rest at maxRows
// (non-positive means one chunk), preserving order. Rejection rows have no
// key, so unlike route records no duplicate rule applies.
func splitRejectionBatches(records []*RejectionRecord, maxRows int) [][]*RejectionRecord {
	var out [][]*RejectionRecord
	var cur []*RejectionRecord
	for _, r := range records {
		if r == nil {
			continue
		}
		if maxRows > 0 && len(cur) >= maxRows {
			out = append(out, cur)
			cur = nil
		}
		cur = append(cur, r)
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}
