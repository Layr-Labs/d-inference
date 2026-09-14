package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type (
	MemoryStore = memory.Store
)

func NewMemory(scfg Config) *MemoryStore {
	return memory.New(scfg)
}
