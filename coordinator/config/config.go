// Package config aggregates per-package configuration structs into a single
// AppConfig and provides shared helpers for reading environment variables.
//
// Each package in the coordinator owns its own Config struct and ReadConfig()
// function. AppConfig composes them so main.go receives a single validated
// configuration object instead of reading dozens of environment variables inline.
//
// Pattern adapted from: https://github.com/Layr-Labs/eigenda-proxy
package config

import "github.com/eigeninference/d-inference/coordinator/env"

// EnvOr delegates to env.EnvOr.
func EnvOr(key, fallback string) string { return env.EnvOr(key, fallback) }

// FirstNonEmpty delegates to env.FirstNonEmpty.
func FirstNonEmpty(vals ...string) string { return env.FirstNonEmpty(vals...) }

// EnvFloat delegates to env.EnvFloat.
func EnvFloat(key string, fallback float64) float64 { return env.EnvFloat(key, fallback) }

// EnvInt delegates to env.EnvInt.
func EnvInt(key string, fallback int) int { return env.EnvInt(key, fallback) }
