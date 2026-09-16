// Package routequeue owns bounded, nonblocking persistence of routing telemetry.
// One FIFO worker groups inserts and outcome updates while preserving order per
// request/attempt. Generic closures retain their queue position. Capacity drops,
// row-fault retries, store failures and bounded shutdown remain observable.
// Callers Bind the store before publishing typed operations.
package routequeue
