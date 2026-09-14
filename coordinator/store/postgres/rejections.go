package postgres

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

// RecordRejection writes a rejected-request record with its counterfactual
// servability snapshot. Best-effort; failures are discarded and never block
// the request path.
func (s *Store) RecordRejection(record *contracts.RejectionRecord) error {
	if record == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	createdAt := record.CreatedAt
	if createdAt.IsZero() {
		createdAt = time.Now().UTC()
	}

	// Mirror marshalProviderLocation's JSONB handling: pass nil (→ SQL NULL)
	// when there are no params so we never write an invalid empty JSONB value.
	var params json.RawMessage
	if len(record.Params) > 0 {
		params = record.Params
	}

	_, _ = s.pool.Exec(ctx,
		`INSERT INTO request_rejections (
			request_id, endpoint, stage, reason_code, http_status, consumer_key_hash, key_id, client_class,
			requested_model, resolved_model, stream, n, estimated_prompt_tokens, requested_max_tokens,
			requires_vision, has_image, has_audio, has_tools, tool_count, response_format, self_route_only, prefer_owner,
			params, request_body_bytes, retry_after_ms,
			could_have_served, candidate_count, capacity_rejections, model_too_large_rejections, vision_rejections,
			warm_provider_existed, best_ttft_ms, shortfall_micro_usd, limit_kind, over_by,
			created_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8,
			$9, $10, $11, $12, $13, $14,
			$15, $16, $17, $18, $19, $20, $21, $22,
			$23, $24, $25,
			$26, $27, $28, $29, $30,
			$31, $32, $33, $34, $35,
			$36
		)`,
		record.RequestID, record.Endpoint, record.Stage, record.ReasonCode, record.HTTPStatus, record.ConsumerKeyHash, record.KeyID, record.ClientClass,
		record.RequestedModel, record.ResolvedModel, record.Stream, record.N, record.EstimatedPromptTokens, record.RequestedMaxTokens,
		record.RequiresVision, record.HasImage, record.HasAudio, record.HasTools, record.ToolCount, record.ResponseFormat, record.SelfRouteOnly, record.PreferOwner,
		params, record.RequestBodyBytes, record.RetryAfterMs,
		record.CouldHaveServed, record.CandidateCount, record.CapacityRejections, record.ModelTooLargeRejections, record.VisionRejections,
		record.WarmProviderExisted, record.BestTTFTMs, record.ShortfallMicroUSD, record.LimitKind, record.OverBy,
		createdAt,
	)
	return nil
}

// RejectionRecordsSince returns rejection records created at or after the given
// time. Zero since returns all records.
func (s *Store) RejectionRecordsSince(since time.Time) []contracts.RejectionRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT * FROM request_rejections WHERE created_at >= $1 ORDER BY created_at DESC LIMIT $2`,
		since, routerecord.MaxTelemetryReadRows)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []contracts.RejectionRecord
	for rows.Next() {
		var r contracts.RejectionRecord
		var id int64
		var paramsRaw []byte

		if err := rows.Scan(
			&id,
			&r.RequestID, &r.Endpoint, &r.Stage, &r.ReasonCode, &r.HTTPStatus, &r.ConsumerKeyHash, &r.KeyID, &r.ClientClass,
			&r.RequestedModel, &r.ResolvedModel, &r.Stream, &r.N, &r.EstimatedPromptTokens, &r.RequestedMaxTokens,
			&r.RequiresVision, &r.HasImage, &r.HasAudio, &r.HasTools, &r.ToolCount, &r.ResponseFormat, &r.SelfRouteOnly, &r.PreferOwner,
			&paramsRaw, &r.RequestBodyBytes, &r.RetryAfterMs,
			&r.CouldHaveServed, &r.CandidateCount, &r.CapacityRejections, &r.ModelTooLargeRejections, &r.VisionRejections,
			&r.WarmProviderExisted, &r.BestTTFTMs, &r.ShortfallMicroUSD, &r.LimitKind, &r.OverBy,
			&r.CreatedAt,
		); err != nil {
			continue
		}
		if len(paramsRaw) > 0 {
			r.Params = paramsRaw
		}
		records = append(records, r)
	}
	return records
}
