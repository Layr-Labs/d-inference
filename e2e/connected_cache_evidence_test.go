package e2e

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
)

func validateConnectedCase(row connectedCase, cache, mtp, expect string) error {
	var dispatches, lookups, terminals, cancels, cancelledTerminals int
	var usage protocol.UsageInfo
	var mtpActive *bool
	var requestID string
	for _, event := range row.Wire {
		switch event.Type {
		case "inference_request":
			dispatches++
			requestID = event.RequestID
			var encrypted, scope bool
			_ = json.Unmarshal(event.Fields["encrypted_body_present"], &encrypted)
			_ = json.Unmarshal(event.Fields["cache_scope_present"], &scope)
			if !encrypted {
				return fmt.Errorf("dispatch was not encrypted")
			}
			var echo string
			_ = json.Unmarshal(event.Fields["cache_receipt_boundary_mode"], &echo)
			shouldParticipate := cache == "ssd" && expect != "vision" && expect != "outage"
			if shouldParticipate && (!scope || echo != "checkpoint") {
				return fmt.Errorf("checkpoint cache capability was not negotiated")
			}
			if (expect == "vision" || expect == "outage") && scope {
				return fmt.Errorf("cold-only request received cache scope")
			}
		case "prefix_cache_lookup_v2":
			lookups++
		case "cancel":
			cancels++
		case "inference_complete":
			terminals++
			_ = json.Unmarshal(event.Fields["usage"], &usage)
			var profile protocol.InferenceProfile
			_ = json.Unmarshal(event.Fields["profile"], &profile)
			mtpActive = profile.MTPActive
			if profile.CancelReceivedUS != nil && profile.CancelAbortedUS != nil && *profile.CancelAbortedUS >= *profile.CancelReceivedUS {
				cancelledTerminals++
			}
		case "inference_error":
			if expect != "cancel" {
				return fmt.Errorf("provider inference_error")
			}
			var cause string
			_ = json.Unmarshal(event.Fields["terminal_cause"], &cause)
			if cause == "cancelled" {
				terminals++
				cancelledTerminals++
			}
		}
	}
	if dispatches != 1 || requestID == "" {
		return fmt.Errorf("expected exactly one correlated dispatch, got %d", dispatches)
	}
	for _, event := range row.Wire {
		if event.RequestID != "" && event.RequestID != requestID {
			return fmt.Errorf("unrelated attempt contaminated sequential case")
		}
	}
	if expect == "cancel" {
		if !row.HTTP.CancelledByClient || row.HTTP.Done || cancels != 1 || terminals != 1 || cancelledTerminals != 1 {
			return fmt.Errorf("cancellation not exercised and retired (fast finish is not proof)")
		}
	}
	if terminals != 1 || (expect != "cancel" && (!row.HTTP.Done || row.HTTP.Finish == "")) || usage.CompletionTokens <= 0 {
		return fmt.Errorf("missing successful terminal/count/finish")
	}
	if mtpActive == nil || *mtpActive != (mtp == "on") {
		return fmt.Errorf("provider profile does not prove normal MTP mode")
	}
	if cache == "off" || expect == "cold" || expect == "vision" || expect == "outage" {
		if usage.CachedTokens != 0 || usage.PrefillTokensSaved != 0 {
			return fmt.Errorf("cold/isolated case reused prefix")
		}
	} else if expect == "hit" || expect == "branch" || expect == "cancel" {
		if usage.CacheOutcome != "hit" || usage.CacheTier != "ssd" || usage.PrefillTokensSaved <= 0 || usage.CachedTokens <= 0 {
			return fmt.Errorf("terminal does not prove actual native SSD reuse")
		}
		if row.After.Lifecycle.SSDHits <= row.Before.Lifecycle.SSDHits {
			return fmt.Errorf("no accepted coordinator hit receipt")
		}
	}
	if cache == "ssd" && expect != "vision" && expect != "outage" {
		if lookups != 1 || row.After.Lifecycle.SSDLookups-row.Before.Lifecycle.SSDLookups != 1 {
			return fmt.Errorf("observed lookup was not uniquely accepted")
		}
	}
	if expect == "tools" {
		if row.HTTP.Finish != "tool_calls" || len(row.HTTP.Tools) != 1 {
			return fmt.Errorf("forced tools did not finish with one call")
		}
		for _, tool := range row.HTTP.Tools {
			var args map[string]any
			if tool.Name != "record_color" || json.Unmarshal([]byte(tool.Arguments), &args) != nil || args["color"] != "blue" || args["count"] != float64(2) {
				return fmt.Errorf("forced tool schema/arguments mismatch")
			}
		}
	} else if strings.TrimSpace(row.HTTP.Content+row.HTTP.Reasoning) == "" {
		return fmt.Errorf("empty served content")
	}
	return nil
}
func validateConnectedBranch(row connectedCase, prior []connectedCase) error {
	for _, event := range row.Wire {
		if event.Type != "prefix_cache_lookup_v2" {
			continue
		}
		var matched int
		_ = json.Unmarshal(event.Fields["matched_anchor_tokens"], &matched)
		if matched == 0 {
			return nil
		}
		for _, old := range prior {
			for _, ready := range old.Wire {
				if old.Tenant != row.Tenant || ready.Connection != event.Connection || ready.Type != "prefix_cache_ready_v2" {
					continue
				}
				var positions []int
				_ = json.Unmarshal(ready.Fields["ready_positions"], &positions)
				for _, position := range positions {
					if position == matched {
						return nil
					}
				}
			}
		}
		return fmt.Errorf("short prompt reused an endpoint not explicitly published by its selected provider")
	}
	return nil
}

// Correlate HTTP selection with the existing scheduler decision for this
// dispatched request. An SSD hit alone does not prove a routing hint existed.
func validateConnectedRoute(row connectedCase, routes []map[string]any, cache, expect string) error {
	var requestID string
	for _, event := range row.Wire {
		if event.Type == "inference_request" {
			requestID = event.RequestID
		}
	}
	for _, route := range routes {
		if route["request_id"] != requestID {
			continue
		}
		if row.HTTP.ProviderID == "" || route["winner"] != row.HTTP.ProviderID {
			return fmt.Errorf("HTTP selected provider differs from scheduler winner")
		}
		if cache == "ssd" && (expect == "hit" || expect == "branch") && route["cache_tier"] != "ssd" {
			return fmt.Errorf("SSD restore occurred without observed SSD routing hint")
		}
		return nil
	}
	return fmt.Errorf("missing correlated scheduler decision")
}
