package receipts

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

const (
	maxCanonicalJSONBytes = 16 << 20
	maxCanonicalJSONDepth = 256
)

// CanonicalJSON returns the version-1 canonical encoding of raw JSON. Version 1
// accepts exactly one top-level object, rejects duplicate decoded object keys
// at every depth, preserves number lexemes, and marshals the decoded value with
// encoding/json's sorted map keys and default string escaping. Whitespace and
// input string escape choices are normalized by decoding and re-encoding. The
// raw input is limited to 16 MiB and nested arrays/objects, including the root
// object, are limited to a depth of 256.
func CanonicalJSON(raw []byte) ([]byte, error) {
	if len(raw) > maxCanonicalJSONBytes {
		return nil, errors.New("canonical JSON input exceeds 16 MiB")
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	first, err := decoder.Token()
	if err != nil {
		return nil, errors.New("canonical JSON must contain one object")
	}
	opening, ok := first.(json.Delim)
	if !ok || opening != '{' {
		return nil, errors.New("canonical JSON top-level value must be an object")
	}
	value, err := decodeCanonicalObject(decoder, 1)
	if err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		if err != nil {
			return nil, errors.New("canonical JSON has invalid trailing data")
		}
		return nil, errors.New("canonical JSON must contain exactly one value")
	}

	canonical, err := json.Marshal(value)
	if err != nil {
		return nil, errors.New("could not encode canonical JSON")
	}
	return canonical, nil
}

// HashCanonicalJSON hashes the version-1 canonical encoding of raw JSON.
func HashCanonicalJSON(raw []byte) (string, error) {
	canonical, err := CanonicalJSON(raw)
	if err != nil {
		return "", err
	}
	return HashBytes(canonical), nil
}

func decodeCanonicalObject(decoder *json.Decoder, depth int) (map[string]any, error) {
	if depth > maxCanonicalJSONDepth {
		return nil, errors.New("canonical JSON nesting exceeds depth 256")
	}
	object := make(map[string]any)
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, errors.New("invalid canonical JSON object")
		}
		if delimiter, ok := token.(json.Delim); ok && delimiter == '}' {
			return object, nil
		}
		key, ok := token.(string)
		if !ok {
			return nil, errors.New("invalid canonical JSON object key")
		}
		if _, exists := object[key]; exists {
			return nil, errors.New("canonical JSON contains a duplicate object key")
		}
		value, err := decodeCanonicalValue(decoder, depth)
		if err != nil {
			return nil, err
		}
		object[key] = value
	}
}

func decodeCanonicalArray(decoder *json.Decoder, depth int) ([]any, error) {
	if depth > maxCanonicalJSONDepth {
		return nil, errors.New("canonical JSON nesting exceeds depth 256")
	}
	array := make([]any, 0)
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, errors.New("invalid canonical JSON array")
		}
		if delimiter, ok := token.(json.Delim); ok && delimiter == ']' {
			return array, nil
		}
		value, err := decodeCanonicalToken(decoder, token, depth)
		if err != nil {
			return nil, err
		}
		array = append(array, value)
	}
}

func decodeCanonicalValue(decoder *json.Decoder, parentDepth int) (any, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, errors.New("invalid canonical JSON value")
	}
	return decodeCanonicalToken(decoder, token, parentDepth)
}

func decodeCanonicalToken(decoder *json.Decoder, token json.Token, parentDepth int) (any, error) {
	delimiter, isDelimiter := token.(json.Delim)
	if !isDelimiter {
		return token, nil
	}
	switch delimiter {
	case '{':
		return decodeCanonicalObject(decoder, parentDepth+1)
	case '[':
		return decodeCanonicalArray(decoder, parentDepth+1)
	default:
		return nil, errors.New("invalid canonical JSON container")
	}
}
