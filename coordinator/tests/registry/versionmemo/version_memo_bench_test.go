package versionmemo_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/versionmemo"
)

func BenchmarkVersionMemoCompare(b *testing.B) {
	var memo versionmemo.Memo[[]int]
	versionmemo.Compare(&memo, "0.9.9", "0.9.6")
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		versionmemo.Compare(&memo, "0.9.9", "0.9.6")
	}
}

func BenchmarkVersionMemoParallel(b *testing.B) {
	var memo versionmemo.Memo[[]int]
	versionmemo.Compare(&memo, "0.9.9", "0.9.6")
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			versionmemo.Compare(&memo, "0.9.9", "0.9.6")
		}
	})
}

func BenchmarkVersionMemoFullCacheMiss(b *testing.B) {
	var memo versionmemo.Memo[int]
	compute := func(key string) int { return len(key) }
	for i := 0; i < versionMemoCap; i++ {
		memo.Load(fmt.Sprintf("9.%d.0", i), compute, nil)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		memo.Load("uncached", compute, nil)
	}
}
