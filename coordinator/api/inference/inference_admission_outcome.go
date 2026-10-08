package inference

// admissionOutcome separates completed evaluation from terminal I/O. A handled
// outcome with no action has already been applied by a failed acquisition or
// fallback callback while the permit was released.
type admissionOutcome struct {
	model          string
	handled        bool
	applyRejection func()
}

func rejectedAdmission(model string, apply func()) admissionOutcome {
	return admissionOutcome{model: model, handled: true, applyRejection: apply}
}
