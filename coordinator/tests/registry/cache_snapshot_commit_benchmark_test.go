package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func BenchmarkCacheSnapshotCommit(b *testing.B) {
	r := production.New(testLogger())
	p := r.Register("snapshot", nil, &protocol.RegisterMessage{PrefixCacheProtocol: 2})
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := r.UpdatePrefixCacheSnapshot(p.ID, false, 2, nil, nil, nil, nil); err != nil {
			b.Fatal(err)
		}
	}
}
