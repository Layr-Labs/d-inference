//go:build !native_pair_hardware_experiment

package main

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/api"
	"net/http"
)

type nativeHardwareExperiment struct{}

func configureNativeHardware(*api.ServerConfig) (*nativeHardwareExperiment, error) { return nil, nil }
func serveNativeHardware(_ *nativeHardwareExperiment, h *http.Server, _ *api.Server, _ context.Context) error {
	return h.ListenAndServe()
}
