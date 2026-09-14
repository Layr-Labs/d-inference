package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func As[T any](s any) (T, bool) {
	return contracts.As[T](s)
}
