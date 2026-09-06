package api

// The retired public telemetry endpoint keeps its explicit 410 response for
// older clients. The field allowlist remains a schema contract shared with the
// Swift and TypeScript producers; client event ingestion is permanently disabled.

import "net/http"

// telemetryFieldAllowlist is the shared schema contract for telemetry fields.
// It does not enable ingestion through the retired HTTP endpoint.
//
// Rule: this list contains only non-sensitive operational fields. Prompt or
// response content MUST NEVER appear here.
var telemetryFieldAllowlist = map[string]struct{}{
	// Generic
	"component":   {},
	"operation":   {},
	"duration_ms": {},
	"attempt":     {},
	"endpoint":    {},
	"status_code": {},
	"error_class": {},
	"error":       {},
	"target":      {},
	// Provider / backend
	"model":         {},
	"backend":       {},
	"exit_code":     {},
	"signal":        {},
	"hardware_chip": {},
	"memory_gb":     {},
	"macos_version": {},
	// Boot-security posture (non-sensitive; provider-reported, MDM remains authoritative).
	"boot_macos_major": {},
	"boot_sip_status":  {},
	// Coordinator
	"handler":           {},
	"provider_id":       {},
	"trust_level":       {},
	"queue_depth":       {},
	"reason":            {},
	"runtime_component": {},
	// Connectivity
	"reconnect_count":   {},
	"last_error":        {},
	"ws_state":          {},
	"network_reachable": {}, // distinguishes "coordinator down" from "box offline"
	"coordinator_url":   {},
	// Billing (booleans/enums only — no dollar amounts)
	"billing_method": {},
	"payment_failed": {},
	// OOM / memory pressure (non-sensitive). Mirror of the Swift allowlist.
	"detect_source":     {},
	"peak_memory_bytes": {},
	"report":            {},
	"pressure":          {},
	"available_bytes":   {},
	"mlx_active_bytes":  {},
	"memory_pressure":   {},
	"in_flight":         {},
	// Engine-health / first-token-wedge diagnostics (non-sensitive operational
	// counters). Mirror of the Swift + TS allowlists. NEVER prompt/response data.
	"steps_executed":                         {},
	"admits":                                 {},
	"first_tokens_emitted":                   {},
	"consecutive_admits_without_first_token": {},
	"seconds_since_last_step":                {},
	"seconds_since_last_first_token":         {},
	"num_running":                            {},
	"wedge_suspected":                        {},
	// Eval-in-flight + idle-clear + prefill-sampling-health diagnostics.
	"eval_in_flight_ms":               {},
	"longest_eval_ms":                 {},
	"evals_completed":                 {},
	"idle_clear_in_flight_ms":         {},
	"idle_clears_completed":           {},
	"prefill_samples_accepted":        {},
	"prefill_samples_dropped_floor":   {},
	"prefill_samples_dropped_ceiling": {},
	"last_prefill_sample_tps":         {},
	"observed_prefill_tps_ewma":       {},
	// KV-budget sustained-rejection audit (v0.7.3 black-hole hardening):
	// reservation ids/byte counts/ages + memory snapshot terms — operational
	// bookkeeping only. Mirror of the Swift + TS allowlists.
	"streak_seconds":         {},
	"reservation_count":      {},
	"reserved_bytes":         {},
	"mlx_cache_bytes":        {},
	"system_available_bytes": {},
	"reservations":           {},
	"request_id":             {},
	"age_seconds":            {},
	// Media-through-engine_v2 tags (v0.7.4 bool + v0.7.5 kind) — a bare
	// boolean and a coarse image/video/mixed label; media/prompt content
	// NEVER rides telemetry. Mirror of the Swift + TS allowlists.
	"multimodal": {},
	"media_kind": {},
	// Exact-prefix replay diagnostics: bounded strategy/reason values and
	// aggregate token counts only. Never prompt/token content or cache keys.
	"prefix_reuse_strategy":       {},
	"prefix_matched_tokens":       {},
	"prefix_replay_tokens":        {},
	"prefix_saved_tokens":         {},
	"prefix_boundary_splits":      {},
	"prefix_construction_failure": {},
	"prefix_capacity_refusal":     {},
	"prefix_cold_fallback":        {},
	// KV-backend discriminator (v0.8.0 paged rollout). `backend` names the
	// ENGINE or runtime ("engine_v2", "mlx-swift"); `kv_backend` names the KV
	// storage kind ("paged" | "contiguous") and is deliberately the same key
	// as BackendSlotCapacity.KVBackend on the heartbeat wire, so telemetry and
	// per-slot capacity group identically. `prefix_reuse_backend` is the finer
	// prefix-reuse row identity (contiguous_unquantized | contiguous_quantized
	// | paged_fp16 | unknown) that "contiguous" alone cannot express.
	"kv_backend":           {},
	"prefix_reuse_backend": {},
	// Paged KV pool metrics (v0.8.0). Aggregate pool counters only — never
	// page contents or block hashes. Mirror of the Swift + TS allowlists.
	// pages_pinned and cow_events are deliberately NOT allowlisted. Neither
	// mechanism exists: PagedKVPool has no pin concept (only reserve/in-use)
	// and copy-on-write page splitting is unimplemented — every page is
	// refcount 0 or 1. An allowlisted key with no producer is worse than an
	// absent one, because it reads as a legitimate zero: a panel built on
	// cow_events would report "no COW events" for a feature that does not
	// exist. Add the key WITH its mechanism, in all three mirrors at once.
	"pool_utilization": {},
	// Paged pool re-slice residue (v0.8.0 co-residency). RAW BYTES, and
	// deliberately not a second ratio: pool_utilization above is OCCUPANCY,
	// and a grant-vs-pool ratio under a near-identical name collides with it
	// in every dashboard that groups by kv_backend. A clamped min(a,b)/b also
	// discards the overflow magnitude — precisely the figure needed when a
	// slot's fair share exceeds its committed pool and the box 503s on
	// stranded slabs. pool_bytes is the denominator, emitted so share-of-pool
	// stays derivable from the raw terms. See docs/reference/telemetry-schema.md
	// "Adding a field: one key, one meaning".
	"pool_bytes":                 {},
	"pool_deferred_growth_bytes": {},
	"pool_stranded_bytes":        {},
	// Multi-token prediction (speculative decode) posture. MTP inflates
	// observed_decode_tps with no discriminator, so a partially-MTP fleet
	// biases coordinator routing on a metric it believes is homogeneous;
	// these four make the split visible. mtp_inactive_reason carries
	// MTPFallbackReason values plus "inert_kv_unsupported" — enabled, drafter
	// resident, zero rounds executed, every row skipped as kv_unsupported.
	// Bounded enums and counters only; never draft tokens or prompt content.
	// mtp_proposed_tokens / mtp_accepted_tokens are the CUMULATIVE counters
	// behind mtp_acceptance_rate — the weights a roll-up needs (weight each
	// sample by proposed count; the bare ratio cannot distinguish a 1/1 slot
	// from a 10,000/10,000 slot). Token COUNTS, never token contents.
	"mtp_enabled":         {},
	"mtp_active":          {},
	"mtp_inactive_reason": {},
	"mtp_acceptance_rate": {},
	"mtp_proposed_tokens": {},
	"mtp_accepted_tokens": {},
	// Console UI context
	"url":        {},
	"user_agent": {},
	"route":      {},
}

// handleTelemetryIngest permanently rejects client-supplied telemetry without
// reading, decoding, storing, logging, or forwarding the request body. Keeping
// the route gives old providers an explicit terminal response during rollout.
func (s *Server) handleTelemetryIngest(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusGone, errorResponse(
		"telemetry_ingest_disabled",
		"client telemetry ingestion is disabled",
	))
}
