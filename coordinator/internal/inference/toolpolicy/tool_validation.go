package toolpolicy

import (
	"net/http"
	"regexp"
)

// ValidationError carries the policy failure consumed by the HTTP adapter.
type ValidationError struct {
	Status  int
	Message string
	Param   string
}

func (e *ValidationError) Error() string { return e.Message }

var toolFunctionNamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

func ValidToolFunctionName(name string) bool { return toolFunctionNamePattern.MatchString(name) }

func InvalidToolConstraint(message, param string) error {
	return &ValidationError{
		Status: http.StatusBadRequest, Message: message, Param: param,
	}
}

func UnsupportedToolConstraint(message string) error {
	return &ValidationError{
		Status:  http.StatusUnprocessableEntity,
		Message: message,
		Param:   "tools",
	}
}
