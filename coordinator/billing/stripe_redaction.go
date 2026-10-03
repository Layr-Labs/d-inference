package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// Stripe Redaction Jobs (public preview) redact the personal data on
// Checkout Sessions for account erasure. A job validates, waits in ready,
// runs and ends in succeeded. https://docs.stripe.com/privacy/redaction

// RedactionJob is the subset of a Stripe privacy.redaction_job we use.
type RedactionJob struct {
	ID     string `json:"id"`
	Status string `json:"status"` // created, validating, ready, redacting, succeeded, canceling, canceled, failed
}

// RedactionValidationError is one reason a job cannot run.
type RedactionValidationError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// MaxRedactionObjects is the most Checkout Sessions the worker puts in one
// redaction job.
const MaxRedactionObjects = 10

var checkoutSessionIDRe = regexp.MustCompile(`^cs_[A-Za-z0-9_]{1,255}$`)
var redactionJobIDRe = regexp.MustCompile(`^prj_[A-Za-z0-9_]{1,255}$`)

// CreateRedactionJob creates a job for the Checkout Sessions with
// validation_behavior fix. idempotencyKey keeps a retried create from
// making a second job; Stripe forgets keys after 24 hours.
func (p *StripeProcessor) CreateRedactionJob(sessionIDs []string, idempotencyKey string) (*RedactionJob, error) {
	if len(sessionIDs) == 0 || len(sessionIDs) > MaxRedactionObjects {
		return nil, fmt.Errorf("stripe redaction: want 1 to %d checkout sessions, got %d", MaxRedactionObjects, len(sessionIDs))
	}
	form := url.Values{"validation_behavior": {"fix"}}
	for _, id := range sessionIDs {
		if !checkoutSessionIDRe.MatchString(id) {
			return nil, fmt.Errorf("stripe redaction: invalid checkout session id")
		}
		form.Add("objects[checkout_sessions][]", id)
	}
	return p.redactionJob(http.MethodPost, "/v1/privacy/redaction_jobs", form, idempotencyKey)
}

// GetRedactionJob reads the job's status.
func (p *StripeProcessor) GetRedactionJob(jobID string) (*RedactionJob, error) {
	if !redactionJobIDRe.MatchString(jobID) {
		return nil, fmt.Errorf("stripe redaction: invalid job id")
	}
	return p.redactionJob(http.MethodGet, "/v1/privacy/redaction_jobs/"+jobID, nil, "")
}

// RunRedactionJob starts a ready job. Redaction cannot be undone.
func (p *StripeProcessor) RunRedactionJob(jobID string) (*RedactionJob, error) {
	if !redactionJobIDRe.MatchString(jobID) {
		return nil, fmt.Errorf("stripe redaction: invalid job id")
	}
	return p.redactionJob(http.MethodPost, "/v1/privacy/redaction_jobs/"+jobID+"/run", url.Values{}, "")
}

// RedactionValidationErrors lists the first page of a failed job's
// validation errors.
func (p *StripeProcessor) RedactionValidationErrors(jobID string) ([]RedactionValidationError, error) {
	if !redactionJobIDRe.MatchString(jobID) {
		return nil, fmt.Errorf("stripe redaction: invalid job id")
	}
	body, err := p.stripeDo(http.MethodGet, "/v1/privacy/redaction_jobs/"+jobID+"/validation_errors?limit=100", nil, "")
	if err != nil {
		return nil, err
	}
	var list struct {
		Data []RedactionValidationError `json:"data"`
	}
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("stripe redaction: parse validation errors: %w", err)
	}
	return list.Data, nil
}

func (p *StripeProcessor) redactionJob(method, path string, form url.Values, idempotencyKey string) (*RedactionJob, error) {
	body, err := p.stripeDo(method, path, form, idempotencyKey)
	if err != nil {
		return nil, err
	}
	var job RedactionJob
	if err := json.Unmarshal(body, &job); err != nil {
		return nil, fmt.Errorf("stripe redaction: parse job: %w", err)
	}
	if job.ID == "" || job.Status == "" {
		return nil, errors.New("stripe redaction: response had no job id or status")
	}
	return &job, nil
}

// stripeDo sends one form request with the Checkout key and returns a
// typed *APIError for a non-2xx answer.
func (p *StripeProcessor) stripeDo(method, path string, form url.Values, idempotencyKey string) ([]byte, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequest(method, stripeAPIBase+path, body)
	if err != nil {
		return nil, fmt.Errorf("stripe: build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+p.secretKey)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("stripe: api request: %w", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("stripe: read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var envelope struct {
			Error struct {
				Message string `json:"message"`
				Code    string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(respBody, &envelope) == nil && envelope.Error.Message != "" {
			return nil, &APIError{StatusCode: resp.StatusCode, Code: envelope.Error.Code, Message: envelope.Error.Message}
		}
		return nil, &APIError{StatusCode: resp.StatusCode, Message: http.StatusText(resp.StatusCode)}
	}
	return respBody, nil
}

// IsNotFoundAPIErr reports whether Stripe answered that the object does not
// exist (HTTP 404 or code resource_missing).
func IsNotFoundAPIErr(err error) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && (apiErr.StatusCode == http.StatusNotFound || apiErr.Code == "resource_missing")
}

// CheckoutSessionExists reports whether the Checkout Session exists under
// the current key. A redaction job cannot say which of its sessions is
// missing, so the worker asks one by one.
func (p *StripeProcessor) CheckoutSessionExists(sessionID string) (bool, error) {
	if !checkoutSessionIDRe.MatchString(sessionID) {
		return false, fmt.Errorf("stripe redaction: invalid checkout session id")
	}
	_, err := p.stripeDo(http.MethodGet, "/v1/checkout/sessions/"+sessionID, nil, "")
	if IsNotFoundAPIErr(err) {
		return false, nil
	}
	return err == nil, err
}
