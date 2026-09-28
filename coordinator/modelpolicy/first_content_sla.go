package modelpolicy

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

func bonsaiFirstContentSLA() firstContentDeadlineBases {
	return firstContentDeadlineBases{upstream: 10 * time.Second, coordinator: 9 * time.Second,
		perToken: 5 * time.Millisecond, customSLA: true}
}

// SetFirstContentSLAsFromEnv sets exact-model SLAs using
// "model=upstream_base_ms:per_input_token_ms,...". Unlike the older base-only
// tightening policy, this explicitly overrides both terms. Parsing is atomic:
// any invalid entry rejects the entire update. Call once during startup.
func SetFirstContentSLAsFromEnv(raw string) error {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	updates := make(map[string]*firstContentDeadlineBases)
	for _, entry := range strings.Split(raw, ",") {
		pair := strings.SplitN(strings.TrimSpace(entry), "=", 2)
		if len(pair) != 2 || strings.TrimSpace(pair[0]) == "" {
			return fmt.Errorf("expected model=base_ms:per_token_ms")
		}
		model, value := strings.TrimSpace(pair[0]), strings.TrimSpace(pair[1])
		if _, duplicate := updates[model]; duplicate {
			return fmt.Errorf("duplicate model SLA: %s", model)
		}
		if value == "off" {
			updates[model] = nil
			continue
		}
		terms := strings.Split(value, ":")
		if len(terms) != 2 {
			return fmt.Errorf("invalid SLA for %s", model)
		}
		base, e1 := strconv.ParseInt(terms[0], 10, 64)
		slope, e2 := strconv.ParseInt(terms[1], 10, 64)
		if e1 != nil || e2 != nil || base <= int64(FirstContentResponseHeadroom/time.Millisecond) || base > int64(maxFirstContentBase/time.Millisecond) || slope < 0 || slope > 100 {
			return fmt.Errorf("SLA for %s requires base 1001..600000 ms and slope 0..100 ms/token", model)
		}
		updates[model] = &firstContentDeadlineBases{upstream: time.Duration(base) * time.Millisecond,
			coordinator: time.Duration(base)*time.Millisecond - FirstContentResponseHeadroom,
			perToken:    time.Duration(slope) * time.Millisecond, customSLA: true}
	}
	basesMu.Lock()
	defer basesMu.Unlock()
	for model, policy := range updates {
		if policy == nil {
			delete(exactBases, model)
		} else {
			exactBases[model] = *policy
		}
	}
	return nil
}

func addFirstContentSlope(base time.Duration, tokens int, slope time.Duration) time.Duration {
	if tokens <= 0 || slope == 0 {
		return base
	}
	if int64(tokens) > (math.MaxInt64-int64(base))/int64(slope) {
		return time.Duration(math.MaxInt64)
	}
	return base + time.Duration(tokens)*slope
}
