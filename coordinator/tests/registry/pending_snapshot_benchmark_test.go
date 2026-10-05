package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
)

// BenchmarkReserveProviderExPendingService_350x2 adds real pending owners and
// bounded whole-provider service reports to the standard warm fleet. Half of
// the pending leases overlap the report; other reported leases represent local
// provider traffic. Time/op is local reserve/remove cost, not inference latency.
func BenchmarkReserveProviderExPendingService_350x2(b *testing.B) {
	for _, count := range []int{0, 4, 16} {
		b.Run(fmt.Sprintf("pending%d", count), func(b *testing.B) {
			r := buildReserveBenchFleet(b)
			for i := 0; i < reserveBenchProviders; i++ {
				p := r.GetProvider(fmt.Sprintf("bench-%04d", i))
				owners := make([]*production.PendingRequest, count)
				for j := range owners {
					model := reserveBenchModelA
					if j%2 != 0 {
						model = reserveBenchModelB
					}
					owners[j] = &production.PendingRequest{RequestID: fmt.Sprintf("held-%d", j), Model: model, EstimatedPromptTokens: 128 + j%4*128, RequestedMaxTokens: 64}
					if j%3 == 0 {
						owners[j].MarkContentCommitted()
					}
					p.AddPending(owners[j])
				}
				p.Mu().Lock()
				p.CapacityAcceptedAt = time.Now().Add(-time.Second)
				p.PrefillTPS = 1024
				used := float64(count) / 32
				p.BackendCapacity.WholeMacServiceUsed = &used
				for j := range owners {
					id := uuid.NewString()
					if j%2 == 0 {
						id = owners[j].ServiceReservationID()
					}
					p.BackendCapacity.WholeMacServiceReservations = append(p.BackendCapacity.WholeMacServiceReservations,
						protocol.WholeMacServiceReservation{ID: id, UsedFraction: 1.0 / 32})
				}
				for j := range p.BackendCapacity.Slots {
					slot := &p.BackendCapacity.Slots[j]
					slot.MaxConcurrency, slot.ActiveTokenBudgetMax = 24, 1<<20
					slot.ObservedPrefillTPS = 1024 + float64(j)*256
					slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64)}
					*slot.Telemetry.QueuedPrefillTokens = int64(count * 128)
					*slot.Telemetry.PartialPrefillRows = int64(count / 4)
				}
				p.Mu().Unlock()
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				model, request := reserveBenchRequest(i)
				selected, _ := r.ReserveProviderEx(model, request)
				if selected == nil {
					b.Fatal("busy fleet has no provider with headroom")
				}
				selected.RemovePending(request.RequestID)
			}
		})
	}
}
