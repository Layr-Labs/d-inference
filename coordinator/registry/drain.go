package registry

// DrainQueuedRequestsForModel attempts to assign queued requests for a
// single model to available providers. Called when a load_model completes
// so requests don't have to wait for the next heartbeat cycle.
func (r *Registry) DrainQueuedRequestsForModel(model string) {
	r.drainQueuedRequestsForModels([]string{model})
}

func (r *Registry) drainQueuedRequestsForModels(models []string) {
	if r.queue == nil || len(models) == 0 {
		return
	}
	for _, model := range models {
		var skipped []*QueuedRequest
		requeueSkipped := func() {
			for i := len(skipped) - 1; i >= 0; i-- {
				r.queue.RequeueFront(skipped[i])
			}
			skipped = nil
		}
		for {
			req := r.queue.PopNextFresh(model)
			if req == nil {
				requeueSkipped()
				break
			}
			if req.Pending == nil {
				req.Pending = &PendingRequest{
					RequestID:          req.RequestID,
					Model:              model,
					RequestedMaxTokens: defaultRequestedMaxTokens,
				}
			}
			provider, decision := r.ReserveProviderEx(model, req.Pending)
			if provider == nil {
				skipped = append(skipped, req)
				continue
			}
			req.Decision = decision
			requeueSkipped()

			select {
			case <-req.Done():
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			default:
			}

			select {
			case req.ResponseCh <- provider:
				// Successfully assigned.
			case <-req.Done():
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			default:
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
				continue
			}
		}
	}
}
