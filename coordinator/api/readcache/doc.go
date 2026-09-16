// Package readcache owns short-lived response bytes and immutable computed
// values. It owns expiration, invalidation generations and coalesced fills;
// endpoint packages choose keys, TTLs and refresh schedules.
package readcache
