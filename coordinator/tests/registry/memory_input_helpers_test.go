package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
)

func memoryInputPtr(input memorypolicy.Input) *memorypolicy.Input { return &input }
