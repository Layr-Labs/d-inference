package request

import "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"

// JsonValueLen measures a JSON value using the encoder's escaping rules.
func JsonValueLen(v any) int { return jsonvalue.Len(v) }
