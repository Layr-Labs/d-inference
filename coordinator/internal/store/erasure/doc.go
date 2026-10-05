// Package erasure holds the backend-independent part of account erasure: the
// PII rule table, the keys the scrub collects, and the confirm-token and
// wallet hashes. postgres.PostgresStore and memory.MemoryStore both run
// Rules in order; each backend maps every rule name to its own statements.
package erasure
