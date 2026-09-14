package recordutil

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func CloneCodeAttestation(r contracts.CodeAttestation) contracts.CodeAttestation {
	if r.ContinuousCoverageUntil != nil {
		t := *r.ContinuousCoverageUntil
		r.ContinuousCoverageUntil = &t
	}
	return r
}

func CloneHuggingFaceArtifact(a *contracts.HuggingFaceArtifact) *contracts.HuggingFaceArtifact {
	if a == nil {
		return nil
	}
	cp := *a
	return &cp
}

func CloneMetadata(metadata map[string]any) map[string]any {
	if metadata == nil {
		return map[string]any{}
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		return map[string]any{}
	}
	out := map[string]any{}
	if err := json.Unmarshal(data, &out); err != nil {
		return map[string]any{}
	}
	return out
}

func CloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	cp := *t
	return &cp
}

func CloneInt64Ptr(v *int64) *int64 {
	if v == nil {
		return nil
	}
	cp := *v
	return &cp
}

// cloneAPIKey returns a deep copy of a key record so callers can never mutate
// the store's internal state through the returned pointer.
func CloneAPIKey(rec *contracts.APIKey) *contracts.APIKey {
	if rec == nil {
		return nil
	}
	cp := *rec
	cp.LimitMicroUSD = CloneInt64Ptr(rec.LimitMicroUSD)
	cp.RPMLimit = CloneInt64Ptr(rec.RPMLimit)
	cp.ITPMLimit = CloneInt64Ptr(rec.ITPMLimit)
	cp.OTPMLimit = CloneInt64Ptr(rec.OTPMLimit)
	cp.ExpiresAt = CloneTimePtr(rec.ExpiresAt)
	cp.LastUsedAt = CloneTimePtr(rec.LastUsedAt)
	cp.AllowedModels = append([]string(nil), rec.AllowedModels...)
	return &cp
}

// jsonbParam returns nil (SQL NULL) for an empty RawMessage so an empty value
// never reaches JSONB as an invalid zero-length document (mirrors the
// request_rejections params handling).
func JsonbParam(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	return raw
}
