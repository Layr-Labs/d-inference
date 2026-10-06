// Package memory implements store contracts with a single in-process state
// owner. Records are protected by MemoryStore's locks and are lost on restart.
// It is intended for development, testing, and non-durable single instances.
package memory
