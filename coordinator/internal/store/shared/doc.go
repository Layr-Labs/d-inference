// Package shared holds backend-independent persistence rules. It depends only
// on store contracts, not on either backend, so memory and PostgreSQL apply the
// same validation, record projections, and aggregation policies.
package shared
