// Package postgres implements durable persistence. Store owns its pool; domain
// methods retain their SQL transaction boundaries. The schema subpackage contains
// ordered startup DDL, while separately gated backfills remain with the backend.
package postgres
