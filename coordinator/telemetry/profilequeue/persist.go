package profilequeue

import (
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (p *Sink) build(job job) *store.RequestProfileRecord {
	defer saferun.Recover(p.hooks.Logger, "profileSink.build")
	return p.hooks.Build(job.rp, job.ap)
}

func (p *Sink) flush(batch []*store.RequestProfileRecord) {
	if len(batch) == 0 {
		return
	}
	st := p.hooks.Store()
	if st == nil {
		return
	}
	logger := p.hooks.Logger
	defer saferun.Recover(logger, "profileSink")
	if err := st.RecordRequestProfiles(batch); err != nil {
		if logger != nil {
			logger.Error("request_profiles batch write failed", "rows", len(batch), "error", err)
		}
		if p.hooks.Count != nil {
			p.hooks.Count("profiler.records", int64(len(batch)), []string{"status:write_failed"})
		}
		return
	}
	p.written.Add(int64(len(batch)))
	if p.hooks.Count != nil {
		p.hooks.Count("profiler.records", int64(len(batch)), []string{"status:written"})
	}
}
