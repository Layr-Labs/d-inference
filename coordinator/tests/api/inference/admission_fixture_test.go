package inference_test

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
)

func runAdmission(admission *inference.Admission, w http.ResponseWriter, r *http.Request, parsed map[string]any, request inference.AdmissionRequest) inference.AdmissionResult {
	return admission.Run(w, r, parsed, request)
}
