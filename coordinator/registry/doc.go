// Package registry is the coordinator's in-memory provider fleet and routing
// engine. It tracks connected providers (identity, hardware, health, trust,
// pending requests), selects a provider per inference request via a multi-stage
// pipeline (structural gates → capacity/concurrency → reputation → cost), and
// manages provider lifecycle, request queueing, eager model loading, and TPS
// tracking. Trust and reputation state are persisted through the store.Store.
//
// Locking discipline is load-bearing: the global r.mu is the outer lock and a
// per-provider p.mu is inner; modelProvidersMu is taken under r.mu. Methods
// suffixed *Locked assume the caller already holds the relevant lock — see each
// method's doc comment. This package was split from registry.go and
// scheduler.go into per-domain files (methods stay with their receiver). File
// map:
//
//	Core types
//	  registry.go             Registry struct, New, SetStore, Queue/SetQueue
//	  provider.go             Provider: identity, hardware, slots, pending state
//	  pending_request.go      PendingRequest: in-flight handle + reservation finalize
//
//	Lifecycle & queueing
//	  lifecycle.go            Register/Heartbeat/Disconnect/eviction loop
//	  drain.go                assign queued requests when capacity frees up
//	  queue.go                RequestQueue/QueuedRequest: per-model FIFO + timeout
//
//	Routing & selection (live path)
//	  reserve.go              ReserveProvider(Ex)/SelectProvider/selectBestCandidate
//	  admission.go            providerEligible/Routable/CanAdmit structural gates
//	  snapshot.go             snapshotProviderLocked for cost calculation
//	  cost.go                 candidate scoring (slot/backlog/health penalties)
//	  quick_capacity.go       QuickCapacityCheck: fast read-only capacity probe
//	  routing_types.go        routingSnapshot/candidate/costBreakdown/RoutingDecision
//	  routing_constants.go    cost/penalty/KV-cache/TPS tuning constants
//	  routing_log.go          structured routing-decision logging
//
//	Capacity, concurrency & counts
//	  concurrency.go          MaxConcurrency(ForModel) dynamic limits
//	  counters.go             fleet counts + per-model provider tallies, TruncHash
//
//	TPS tracking
//	  tps_registry.go         TPSRegistry: observed decode TPS by model/chip
//	  tps.go                  effective-TPS fallback chain + batch-load scaling
//
//	Trust, attestation & reputation
//	  trust.go                ProviderStatus/TrustLevel enums + TrustMultiplier
//	  trust_state.go          MarkUntrusted/SetTrustLevel/RecordChallenge*/Job*
//	  reputation.go           Reputation: success/uptime/challenge → score
//	  privacy_policy.go       vet providers for encrypted (private-text) routing
//
//	Model catalog & loading
//	  catalog.go              SetModelCatalog, ModelType, weight-hash footprints
//	  model_load.go           eager load_model orchestration + warm detection
//
//	Snapshots, persistence & config
//	  snapshots.go            dedup model/capacity aggregates for /v1/models, /metrics
//	  persistence.go          load/save provider, trust, reputation via store
//	  config.go               Config/ReadConfig/Check from environment
//	  clamp.go                clamp provider-reported metrics against caps
//	  scheduler.go            package doc remnant (routing split into files above)
package registry
