package api

import (
	"errors"
	"math"
	"strconv"
	"strings"
)

var errInvalidUSD = errors.New("amount_usd must be a positive decimal with at most two fractional digits")

func parseUSDCents(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	parts := strings.Split(raw, ".")
	if len(parts) > 2 || len(parts) == 0 || !asciiDigits(parts[0]) {
		return 0, errInvalidUSD
	}
	fraction := ""
	if len(parts) == 2 {
		fraction = parts[1]
		if len(fraction) == 0 || len(fraction) > 2 || !asciiDigits(fraction) {
			return 0, errInvalidUSD
		}
	}
	dollars, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || dollars > (math.MaxInt64-99)/100 {
		return 0, errInvalidUSD
	}
	for len(fraction) < 2 {
		fraction += "0"
	}
	cents := int64(0)
	if fraction != "" {
		cents, err = strconv.ParseInt(fraction, 10, 64)
		if err != nil {
			return 0, errInvalidUSD
		}
	}
	total := dollars*100 + cents
	if total <= 0 || total > math.MaxInt64/10_000 {
		return 0, errInvalidUSD
	}
	return total, nil
}

func asciiDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}
