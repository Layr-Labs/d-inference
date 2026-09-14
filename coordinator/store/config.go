package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func ReadConfig() Config {
	return contracts.ReadConfig()
}
