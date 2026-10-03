package postgres

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store/internal/testdb"
)

func TestMain(m *testing.M) { testdb.Main(m) }
