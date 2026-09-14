// Package requestqueue owns model FIFOs, bounded waiter expiry, assignment
// acknowledgement and drain-pass coalescing. Requests and providers are opaque;
// registry owns eligibility, live reservation, and provider dispatch.
package requestqueue
