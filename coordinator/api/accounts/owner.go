// Package accounts owns account administration and the owner's provider views.
package accounts

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/sync/singleflight"
)

type Store interface {
	store.InviteStore
	store.SmallModelsInterestStore
	GetAccountEarningsSummary(string) (store.ProviderEarningsSummary, error)
	AccountEarningsWindows(string, time.Time) (store.AccountEarningsWindows, error)
	GetBalance(string) int64
	GetWithdrawableBalance(string) int64
	Credit(string, int64, store.LedgerEntryType, string) error
	ListProvidersByAccount(context.Context, string) ([]store.ProviderRecord, error)
	GetProviderRecord(context.Context, string) (*store.ProviderRecord, error)
	GetReputations(context.Context, []string) (map[string]*store.ReputationRecord, error)
	DeleteProvidersBySerial(context.Context, string, string) (int, error)
	SetUserRole(string, string) error
	SetUserPlatformFeePercent(string, *int64) error
}

type Authorizer interface {
	IsAdminAuthorized(http.ResponseWriter, *http.Request) bool
	RequireAdminKey(http.ResponseWriter, *http.Request) bool
}

type Dependencies struct {
	Store                 Store
	Registry              *registry.Registry
	Access                Authorizer
	Logger                *slog.Logger
	ReadCache             *readcache.Cache
	LatestReleasedVersion func() string
	MinProviderVersion    string
	SelfRouteModelEntries func(string, bool) []types.ModelEntry
}

type Owner struct {
	store                 Store
	registry              *registry.Registry
	access                Authorizer
	logger                *slog.Logger
	readCache             *readcache.Cache
	summaryWindowsFlights singleflight.Group
	latestReleasedVersion func() string
	minProviderVersion    string
	selfRouteModelEntries func(string, bool) []types.ModelEntry
}

func New(d Dependencies) *Owner {
	return &Owner{store: d.Store, registry: d.Registry, access: d.Access, logger: d.Logger,
		readCache: d.ReadCache, latestReleasedVersion: d.LatestReleasedVersion,
		minProviderVersion: d.MinProviderVersion, selfRouteModelEntries: d.SelfRouteModelEntries}
}

func (s *Owner) SetMinProviderVersion(version string) { s.minProviderVersion = version }
