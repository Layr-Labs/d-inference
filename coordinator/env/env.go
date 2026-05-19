// Package env provides shared environment variable constants used across
// coordinator subpackages. It exists to avoid import cycles between
// packages that independently reference the same env var prefix.
package env

// EnvPrefix is the namespace prefix for all coordinator environment variables.
const EnvPrefix = "EIGENINFERENCE"
