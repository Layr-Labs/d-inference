package eligibility

import (
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/appattest"
)

// AppendMeasurement records the verified Apple metadata separately from build
// qualification. In particular, a truncated digest is not a complete match.
func AppendMeasurement(fields map[string]any, version string, metadata *appattest.Key) string {
	policy := "matched"
	candidate := metadata.CodeDirectorySHA256Candidate()
	if metadata.ValidationCategory == nil || metadata.BundleVersion == "" && len(candidate) == 0 {
		policy = "metadata_missing"
	} else if *metadata.ValidationCategory != 6 || metadata.BundleVersion != "" && metadata.BundleVersion != version {
		policy = "metadata_mismatch"
	} else if len(candidate) == 20 {
		policy = "truncated_measurement_pending_qualification"
	}
	fields["metadata_comparison"] = policy
	fields["attested_bundle_version"] = metadata.BundleVersion
	if metadata.ValidationCategory != nil {
		fields["attested_validation_category"] = *metadata.ValidationCategory
	}
	if metadata.CodeDirectoryType != nil {
		fields["attested_code_directory_type"] = *metadata.CodeDirectoryType
		fields["attested_code_directory_hash"] = hex.EncodeToString(metadata.CodeDirectoryHash)
		if len(candidate) == 20 {
			fields["attested_code_directory_hash_format"] = "sha256_prefix_20"
		} else if len(candidate) == 32 {
			fields["attested_code_directory_hash_format"] = "sha256_full_32"
		}
	}
	return policy
}
