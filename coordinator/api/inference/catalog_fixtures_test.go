package inference

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"strings"
)

// Fixture addresses are independent of catalog's address builder. Exact address
// validation is tested beside that builder, not by comparing it to itself.
func testModelPrefix(model, version string) string {
	slug := strings.Trim(regexp.MustCompile(`[^a-zA-Z0-9._-]`).ReplaceAllString(model, "-"), "-")
	if slug == "" {
		slug = "model"
	}
	sum := sha256.Sum256([]byte(model))
	return fmt.Sprintf("v2/%s--%x/%s", slug, sum[:6], version)
}
