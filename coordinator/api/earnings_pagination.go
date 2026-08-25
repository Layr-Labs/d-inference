package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	defaultEarningsPageSize = 50
	maxEarningsPageSize     = 1_000
)

type earningsCursorWire struct {
	CreatedAt string `json:"created_at"`
	ID        int64  `json:"id"`
}

func earningsPageRequest(r *http.Request) (int, *store.ProviderEarningsCursor, error) {
	limit := defaultEarningsPageSize
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > maxEarningsPageSize {
		limit = maxEarningsPageSize
	}

	rawCursor := r.URL.Query().Get("cursor")
	if rawCursor == "" {
		return limit, nil, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(rawCursor)
	if err != nil {
		return 0, nil, errors.New("invalid earnings cursor encoding")
	}
	var wire earningsCursorWire
	if err := json.Unmarshal(decoded, &wire); err != nil || wire.ID <= 0 {
		return 0, nil, errors.New("invalid earnings cursor payload")
	}
	createdAt, err := time.Parse(time.RFC3339Nano, wire.CreatedAt)
	if err != nil {
		return 0, nil, errors.New("invalid earnings cursor timestamp")
	}
	return limit, &store.ProviderEarningsCursor{CreatedAt: createdAt, ID: wire.ID}, nil
}

func encodeEarningsCursor(cursor *store.ProviderEarningsCursor) string {
	if cursor == nil {
		return ""
	}
	payload, err := json.Marshal(earningsCursorWire{
		CreatedAt: cursor.CreatedAt.UTC().Format(time.RFC3339Nano),
		ID:        cursor.ID,
	})
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(payload)
}
