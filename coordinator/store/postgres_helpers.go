package store

import (
	"time"

	"encoding/json"
)

// rowScanner is satisfied by both pgx.Row and pgx.Rows.
type rowScanner interface {
	Scan(dest ...any) error
}

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
}

func nullableCreatedAt(ts time.Time) any {
	if ts.IsZero() {
		return nil
	}
	return ts
}

func marshalProviderLocation(loc *ProviderLocation) json.RawMessage {
	if loc == nil {
		return nil
	}
	b, err := json.Marshal(loc)
	if err != nil {
		return nil
	}
	return b
}

func unmarshalProviderLocation(raw []byte) *ProviderLocation {
	if len(raw) == 0 {
		return nil
	}
	var loc ProviderLocation
	if err := json.Unmarshal(raw, &loc); err != nil {
		return nil
	}
	return &loc
}
