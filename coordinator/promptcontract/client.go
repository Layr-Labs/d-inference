package promptcontract

import "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"

const (
	DefaultSocketPath       = sidecar.DefaultSocketPath
	DefaultRequestTimeout   = sidecar.DefaultRequestTimeout
	DefaultHealthTimeout    = sidecar.DefaultHealthTimeout
	DefaultPreloadTimeout   = sidecar.DefaultPreloadTimeout
	DefaultMaxRequestBytes  = sidecar.DefaultMaxRequestBytes
	DefaultMaxResponseBytes = sidecar.DefaultMaxResponseBytes
	DefaultMaxTokens        = sidecar.DefaultMaxTokens
	DefaultMaxPreloadIDs    = sidecar.DefaultMaxPreloadIDs
	EndpointChatCompletions = sidecar.EndpointChatCompletions
	EndpointCompletions     = sidecar.EndpointCompletions
	EndpointResponses       = sidecar.EndpointResponses
	EndpointMessages        = sidecar.EndpointMessages
)

type Endpoint = sidecar.Endpoint
type PlanInput = sidecar.PlanInput
type Boundary = sidecar.Boundary
type Plan = sidecar.Plan
type ClientConfig = sidecar.ClientConfig
type Client = sidecar.Client
type ClientStats = sidecar.ClientStats

var (
	ErrSidecarUnavailable = sidecar.ErrSidecarUnavailable
	ErrInvalidPlan        = sidecar.ErrInvalidPlan
	ErrPlanTooLarge       = sidecar.ErrPlanTooLarge
	ErrDynamicContract    = sidecar.ErrDynamicContract
)

func NewClient(config ClientConfig) *Client { return sidecar.NewClient(config) }
