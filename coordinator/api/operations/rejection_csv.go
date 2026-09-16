package operations

import (
	"encoding/csv"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// rejectionCSVHeader lists the rejection export columns in struct-field order.
var rejectionCSVHeader = []string{
	"request_id", "endpoint", "stage", "reason_code", "http_status",
	"consumer_key_hash", "key_id", "client_class",
	"requested_model", "resolved_model", "stream", "n",
	"estimated_prompt_tokens", "requested_max_tokens",
	"requires_vision", "has_image", "has_audio", "has_tools", "tool_count",
	"response_format", "self_route_only", "prefer_owner", "params",
	"request_body_bytes", "retry_after_ms",
	"could_have_served", "candidate_count", "capacity_rejections",
	"model_too_large_rejections", "vision_rejections", "warm_provider_existed",
	"best_ttft_ms", "shortfall_micro_usd", "limit_kind", "over_by",
	"created_at",
}

// writeRejectionCSV streams a header row followed by one row per record to w,
// then flushes and reports any write error.
func writeRejectionCSV(w http.ResponseWriter, records []store.RejectionRecord) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(rejectionCSVHeader); err != nil {
		return err
	}
	for i := range records {
		if err := cw.Write(guardCSVRow(rejectionCSVRow(records[i]))); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// rejectionCSVRow flattens one record into CSV cells matching
// rejectionCSVHeader. The json.RawMessage Params field is emitted as a string.
func rejectionCSVRow(rec store.RejectionRecord) []string {
	return []string{
		rec.RequestID,
		rec.Endpoint,
		rec.Stage,
		rec.ReasonCode,
		csvInt(rec.HTTPStatus),
		rec.ConsumerKeyHash,
		rec.KeyID,
		rec.ClientClass,
		rec.RequestedModel,
		rec.ResolvedModel,
		csvBool(rec.Stream),
		csvInt(rec.N),
		csvInt(rec.EstimatedPromptTokens),
		csvInt(rec.RequestedMaxTokens),
		csvBool(rec.RequiresVision),
		csvBool(rec.HasImage),
		csvBool(rec.HasAudio),
		csvBool(rec.HasTools),
		csvInt(rec.ToolCount),
		rec.ResponseFormat,
		csvBool(rec.SelfRouteOnly),
		csvBool(rec.PreferOwner),
		string(rec.Params),
		csvInt(rec.RequestBodyBytes),
		csvInt(rec.RetryAfterMs),
		csvOptionalBool(rec.CouldHaveServed),
		csvInt(rec.CandidateCount),
		csvInt(rec.CapacityRejections),
		csvInt(rec.ModelTooLargeRejections),
		csvInt(rec.VisionRejections),
		csvBool(rec.WarmProviderExisted),
		csvFloat(rec.BestTTFTMs),
		csvI64(rec.ShortfallMicroUSD),
		rec.LimitKind,
		csvI64(rec.OverBy),
		csvTime(rec.CreatedAt),
	}
}
