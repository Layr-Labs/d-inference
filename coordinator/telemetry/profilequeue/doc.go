// Package profilequeue owns the bounded worker for sampled request profiles.
// It builds records off the request path and writes batches through injected
// dependencies. Its buffer and close policy are independent of route and
// compact outcome persistence.
package profilequeue
