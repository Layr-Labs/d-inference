package promptcontract

import "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"

var ErrPreloadRejected = sidecar.ErrPreloadRejected

type ReadinessStatus = sidecar.ReadinessStatus
type PreloadResult = sidecar.PreloadResult
type PreloadReport = sidecar.PreloadReport
type SidecarStatus = sidecar.SidecarStatus
type SidecarMetrics = sidecar.SidecarMetrics
type SidecarPlanMetrics = sidecar.SidecarPlanMetrics
type SidecarContractMetrics = sidecar.SidecarContractMetrics
type SidecarPreloadMetrics = sidecar.SidecarPreloadMetrics
type SidecarLatencySnapshot = sidecar.SidecarLatencySnapshot
type SidecarLatencyBucket = sidecar.SidecarLatencyBucket
