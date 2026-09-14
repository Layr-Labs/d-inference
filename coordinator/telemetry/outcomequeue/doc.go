// Package outcomequeue owns the unsampled compact request-outcome buffer.
// It does no classification or billing: callers submit owned snapshots, and
// the worker batches their persistence with a bounded close-time drain.
package outcomequeue
