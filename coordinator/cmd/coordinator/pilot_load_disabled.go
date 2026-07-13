//go:build !pilotload

package main

import "github.com/eigeninference/d-inference/coordinator/store"

func seedPilotLoadState(store.Store) error {
	return nil
}

func pilotListenAddress(port string) string {
	return ":" + port
}
