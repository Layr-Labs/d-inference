package api

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	maxProviderWaitlistBodyBytes int64 = 4 << 10
	providerWaitlistRPS                = 1.0 / 60.0
	providerWaitlistBurst              = 3
)

var providerWaitlistChips = map[string]string{
	"m1":       "M1",
	"m1 pro":   "M1 Pro",
	"m1 max":   "M1 Max",
	"m1 ultra": "M1 Ultra",
	"m2":       "M2",
	"m2 pro":   "M2 Pro",
	"m2 max":   "M2 Max",
	"m2 ultra": "M2 Ultra",
	"m3":       "M3",
	"m3 pro":   "M3 Pro",
	"m3 max":   "M3 Max",
	"m3 ultra": "M3 Ultra",
	"m4":       "M4",
	"m4 pro":   "M4 Pro",
	"m4 max":   "M4 Max",
	"m5":       "M5",
	"m5 pro":   "M5 Pro",
	"m5 max":   "M5 Max",
	"m5 ultra": "M5 Ultra",
	"m6":       "M6",
	"other":    "other",
}

type providerWaitlistSignupRequest struct {
	Email        string `json:"email"`
	Chip         string `json:"chip"`
	MemoryGB     int    `json:"memory_gb"`
	GPUCores     int    `json:"gpu_cores"`
	OtherMachine string `json:"other_machine"`
	Consent      bool   `json:"consent"`
	Company      string `json:"company"`
}

// NewProviderWaitlistRateLimiter returns the mandatory public-form limiter.
// Three immediate attempts tolerate corrections; sustained traffic recovers at
// one attempt per minute per source IP.
func NewProviderWaitlistRateLimiter() *ratelimit.Limiter {
	return ratelimit.New(ratelimit.Config{
		RPS:        providerWaitlistRPS,
		Burst:      providerWaitlistBurst,
		IdleEvict:  30 * time.Minute,
		PruneEvery: 5 * time.Minute,
	})
}

func (s *Server) rateLimitProviderWaitlist(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		limiter := s.providerWaitlistRateLimiter
		if limiter == nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse(
				"temporarily_unavailable",
				"provider availability registration is temporarily unavailable",
			))
			return
		}

		key := "unknown"
		if ip := providerClientIP(r); ip != nil {
			key = ip.String()
		}
		if allowed, retryAfter := limiter.Allow(key); !allowed {
			seconds := max(1, int(math.Ceil(retryAfter.Seconds())))
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(time.Now().Add(retryAfter).Unix(), 10))
			setRequestRateLimitHeaders(w, limiter.Stat(key))
			s.ddIncr("provider_waitlist.signup", []string{"result:rate_limited"})
			writeJSON(w, http.StatusTooManyRequests, errorResponse(
				"rate_limit_exceeded",
				"too many registration attempts — retry after the Retry-After interval",
			))
			return
		}
		setRequestRateLimitHeaders(w, limiter.Stat(key))
		next(w, r)
	}
}

func (s *Server) handleProviderWaitlistSignup(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var request providerWaitlistSignupRequest
	if !decodeProviderWaitlistRequest(w, r, &request) {
		return
	}

	// Browser-only honeypot. Bots that fill every field receive the same success
	// response without polluting the hardware-interest list.
	if strings.TrimSpace(request.Company) != "" {
		writeJSON(w, http.StatusOK, map[string]bool{"registered": true})
		return
	}

	signup, err := validateProviderWaitlistSignup(request)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := s.store.UpsertProviderWaitlistSignup(r.Context(), signup); err != nil {
		s.logger.Error("provider waitlist signup persistence failed", "error", err)
		s.ddIncr("provider_waitlist.signup", []string{"result:error"})
		writeJSON(w, http.StatusInternalServerError, errorResponse(
			"internal_error",
			"could not save provider availability registration",
		))
		return
	}

	s.ddIncr("provider_waitlist.signup", []string{"result:registered"})
	writeJSON(w, http.StatusOK, map[string]bool{"registered": true})
}

func (s *Server) handleAdminProviderWaitlist(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	limit := 100
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 || parsed > 1000 {
			writeJSON(w, http.StatusBadRequest, errorResponse(
				"invalid_request", "limit must be between 1 and 1000"))
			return
		}
		limit = parsed
	}
	signups, err := s.store.ListProviderWaitlistSignups(r.Context(), limit)
	if err != nil {
		s.logger.Error("provider waitlist listing failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse(
			"internal_error", "could not list provider availability registrations"))
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, map[string]any{"signups": signups})
}

func decodeProviderWaitlistRequest(
	w http.ResponseWriter,
	r *http.Request,
	request *providerWaitlistSignupRequest,
) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxProviderWaitlistBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(request); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse(
				"invalid_request_error",
				"request body too large",
			))
			return false
		}
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error",
			"invalid JSON request",
		))
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error",
			"request body must contain exactly one JSON object",
		))
		return false
	}
	return true
}

func validateProviderWaitlistSignup(
	request providerWaitlistSignupRequest,
) (store.ProviderWaitlistSignup, error) {
	email, err := normalizeProviderWaitlistEmail(request.Email)
	if err != nil {
		return store.ProviderWaitlistSignup{}, err
	}
	if !request.Consent {
		return store.ProviderWaitlistSignup{}, errors.New(
			"data storage acknowledgement is required",
		)
	}

	chipLabel := strings.Join(strings.Fields(request.Chip), " ")
	if detailStart := strings.LastIndex(chipLabel, " ("); detailStart > 0 &&
		strings.HasSuffix(chipLabel, ")") {
		chipLabel = chipLabel[:detailStart]
	}
	chipKey := strings.ToLower(chipLabel)
	chip, ok := providerWaitlistChips[chipKey]
	if !ok {
		return store.ProviderWaitlistSignup{}, errors.New(
			"chip must be a listed Apple Silicon chip or other",
		)
	}
	if request.MemoryGB < 4 || request.MemoryGB > 1024 {
		return store.ProviderWaitlistSignup{}, errors.New(
			"memory_gb must be between 4 and 1024",
		)
	}
	if request.GPUCores < 0 || request.GPUCores > 512 {
		return store.ProviderWaitlistSignup{}, errors.New(
			"gpu_cores must be between 0 and 512",
		)
	}

	otherMachine := strings.TrimSpace(request.OtherMachine)
	if chip == "other" {
		if otherMachine == "" {
			return store.ProviderWaitlistSignup{}, errors.New(
				"other_machine is required when chip is other",
			)
		}
		if utf8.RuneCountInString(otherMachine) > 160 {
			return store.ProviderWaitlistSignup{}, errors.New(
				"other_machine must be at most 160 characters",
			)
		}
		if strings.IndexFunc(otherMachine, unicode.IsControl) >= 0 {
			return store.ProviderWaitlistSignup{}, errors.New(
				"other_machine contains unsupported control characters",
			)
		}
	} else {
		otherMachine = ""
	}

	return store.ProviderWaitlistSignup{
		Email:        email,
		Chip:         chip,
		MemoryGB:     request.MemoryGB,
		GPUCores:     request.GPUCores,
		OtherMachine: otherMachine,
		SubmittedAt:  time.Now().UTC(),
	}, nil
}

func normalizeProviderWaitlistEmail(raw string) (string, error) {
	email := strings.TrimSpace(raw)
	if email == "" || len(email) > 254 || strings.IndexFunc(email, unicode.IsControl) >= 0 {
		return "", errors.New("enter a valid email address")
	}
	address, err := mail.ParseAddress(email)
	if err != nil || address.Name != "" || !strings.EqualFold(address.Address, email) {
		return "", errors.New("enter a valid email address")
	}
	return strings.ToLower(address.Address), nil
}
