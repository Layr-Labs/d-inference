// Package postgres implements store contracts with PostgreSQL transactions.
// NewPostgres owns the connection pool and runs the startup schema migrations.
// API keys are persisted as SHA-256 hashes, never as raw keys. Destructive
// offline maintenance scripts live in migrations and are not run at startup.
package postgres
