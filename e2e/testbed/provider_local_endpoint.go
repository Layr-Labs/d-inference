package testbed

import (
	"fmt"
	"strconv"
)

func localEndpointArguments(port int) ([]string, error) {
	if port == 0 {
		return nil, nil
	}
	if port < 1024 || port > 65535 {
		return nil, fmt.Errorf("local test endpoint port must be 1024..65535 or zero")
	}
	// Native unified mode retains coordinator serving and API-key auth. The
	// key lives in the provider's existing per-test DARKBLOOM_LOCAL_DIR.
	return []string{"--local-endpoint", "--port", strconv.Itoa(port), "--bind", "127.0.0.1"}, nil
}

func validateLocalEndpointSelection(port, providers int, ownedTargets bool) error {
	if _, err := localEndpointArguments(port); err != nil {
		return err
	}
	if port != 0 && (providers != 1 || ownedTargets) {
		return fmt.Errorf("local test endpoint requires exactly one locally launched provider")
	}
	return nil
}
