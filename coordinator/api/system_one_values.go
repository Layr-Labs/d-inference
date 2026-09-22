package api

import (
	"encoding/json"
	"math"
	"math/big"
	"reflect"
	"strings"
)

func nativeNumber(value any) (float64, bool) {
	switch value := value.(type) {
	case json.Number:
		n, err := value.Float64()
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
	case float64:
		return value, !math.IsNaN(value) && !math.IsInf(value, 0)
	default:
		return 0, false
	}
}

func probability(value any) (float64, bool) {
	n, ok := nativeNumber(value)
	return n, ok && n >= 0 && n <= 1
}

func systemOneProbabilities(value any) (map[string]any, bool) {
	probs, ok := value.(map[string]any)
	if !ok || len(probs) == 0 {
		return nil, false
	}
	sum := 0.0
	for _, value := range probs {
		p, ok := probability(value)
		if !ok {
			return nil, false
		}
		sum += p
	}
	// Laya rounds each probability independently to four decimal places.
	return probs, math.Abs(sum-1) <= float64(len(probs))*0.00005+1e-8
}

// Both score and each input probability are independently rounded to four
// decimal places; propagate that bounded error through the weighted sum.
func systemOneScoreRoundingTolerance(levels int) float64 {
	return 0.00005*(1+float64(levels*(levels-1))/2) + 1e-8
}

// Preserve all structured legend numbers exactly while accepting equivalent
// JSON numeric spellings produced by the provider (100, 100.0, 1e2).
func systemOneJSONEqual(a, b any) bool {
	if left, ok := a.(json.Number); ok {
		right, ok := b.(json.Number)
		if !ok {
			return false
		}
		leftDigits, leftExponent := normalizedSystemOneNumber(left.String())
		rightDigits, rightExponent := normalizedSystemOneNumber(right.String())
		return leftDigits == rightDigits && leftExponent.Cmp(rightExponent) == 0
	}
	switch left := a.(type) {
	case map[string]any:
		right, ok := b.(map[string]any)
		if !ok || len(left) != len(right) {
			return false
		}
		for key, value := range left {
			other, exists := right[key]
			if !exists || !systemOneJSONEqual(value, other) {
				return false
			}
		}
		return true
	case []any:
		right, ok := b.([]any)
		if !ok || len(left) != len(right) {
			return false
		}
		for i, value := range left {
			if !systemOneJSONEqual(value, right[i]) {
				return false
			}
		}
		return true
	default:
		return reflect.DeepEqual(a, b)
	}
}

// Compare decimal values symbolically: constructing 10^exponent would let a
// short untrusted JSON number force an arbitrarily large allocation.
func normalizedSystemOneNumber(number string) (string, *big.Int) {
	exponent := new(big.Int)
	if index := strings.IndexAny(number, "eE"); index >= 0 {
		exponent.SetString(number[index+1:], 10)
		number = number[:index]
	}
	negative := strings.HasPrefix(number, "-")
	number = strings.TrimPrefix(number, "-")
	if dot := strings.IndexByte(number, '.'); dot >= 0 {
		exponent.Sub(exponent, big.NewInt(int64(len(number)-dot-1)))
		number = number[:dot] + number[dot+1:]
	}
	number = strings.TrimLeft(number, "0")
	if number == "" {
		return "0", new(big.Int)
	}
	significant := strings.TrimRight(number, "0")
	exponent.Add(exponent, big.NewInt(int64(len(number)-len(significant))))
	if negative {
		significant = "-" + significant
	}
	return significant, exponent
}
