// Package autopilot owns demand aggregation, workload cohorts, placement policy,
// donor coverage, configuration and snapshot validation. It consumes detached
// fleet values and returns plans; it does not access live providers or perform IO.
//
// The registry adapter owns live session identity, locks, reservations, socket
// delivery and reconciliation. API and storage adapters keep their own IO types.
package autopilot
