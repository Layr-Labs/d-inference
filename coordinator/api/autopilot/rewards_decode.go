package autopilot

import (
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"strconv"
)

// Reward mutations reject duplicate keys, case aliases and trailing JSON;
// ordinary struct decoding would otherwise silently accept ambiguous amounts.
func decodeRewardBody(body io.Reader, fields map[string]any) error {
	decoder := json.NewDecoder(body)
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return errors.New("JSON object required")
	}
	seen := make(map[string]bool, len(fields))
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok || fields[key] == nil || seen[key] {
			return errors.New("unknown or duplicate reward field")
		}
		if err := decoder.Decode(fields[key]); err != nil {
			return err
		}
		seen[key] = true
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(seen) != len(fields) {
		return errors.New("all reward fields are required")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("exactly one JSON object required")
	}
	return nil
}

func decodeRewardQuery(rawQuery string) (string, int, error) {
	query, err := url.ParseQuery(rawQuery)
	if err != nil {
		return "", 0, err
	}
	after, limit := "", 100
	for key, values := range query {
		if len(values) != 1 {
			return "", 0, errors.New("duplicate query")
		}
		switch key {
		case "after":
			var valid bool
			after, valid = canonicalMachineID(values[0])
			if !valid {
				return "", 0, errors.New("invalid cursor")
			}
		case "limit":
			limit, err = strconv.Atoi(values[0])
			if err != nil || limit < 1 || limit > 200 {
				return "", 0, errors.New("invalid limit")
			}
		default:
			return "", 0, errors.New("unknown query")
		}
	}
	return after, limit, nil
}
