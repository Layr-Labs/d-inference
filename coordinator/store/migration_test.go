package store

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestMigrationCatalogIsOrderedAndVersionBounded(t *testing.T) {
	migrations, err := loadMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if got := int64(len(migrations)); got != MaximumSupportedSchemaVersion {
		t.Fatalf("catalog size = %d, max supported version = %d", got, MaximumSupportedSchemaVersion)
	}
	for i, migration := range migrations {
		want := int64(i + 1)
		if migration.Version != want {
			t.Fatalf("migration %d version = %d, want %d", i, migration.Version, want)
		}
		if len(migration.Checksum) != 64 {
			t.Fatalf("migration %d checksum length = %d, want 64", migration.Version, len(migration.Checksum))
		}
	}
	if migrations[0].Transactional || !migrations[0].Bootstrap {
		t.Fatal("legacy baseline must be a nontransactional metadata bootstrap")
	}
	rewardIndexPredicate := "entry_type IN (" + rewardLedgerTypesSQLList() + ")"
	var catalogSQL strings.Builder
	for _, migration := range migrations {
		catalogSQL.WriteString(migration.SQL)
	}
	if !strings.Contains(catalogSQL.String(), rewardIndexPredicate) {
		t.Fatalf("migration catalog reward index predicate is out of sync with RewardLedgerTypes: want %q", rewardIndexPredicate)
	}
	indexMigration := migrations[1]
	if indexMigration.Transactional {
		t.Fatal("concurrent index migration must be nontransactional")
	}
	if indexMigration.ConcurrentIndex != "idx_provider_earnings_job" {
		t.Fatalf("concurrent index = %q", indexMigration.ConcurrentIndex)
	}
	rustCompatibilityMigration := migrations[2]
	if !rustCompatibilityMigration.Transactional {
		t.Fatal("Rust schema compatibility migration must be transactional")
	}
	for _, required := range []string{
		"CREATE SCHEMA IF NOT EXISTS rust_coord",
		"CREATE TABLE IF NOT EXISTS rust_coord.schema_versions",
		"VALUES (1, 3, 3)",
	} {
		if !strings.Contains(rustCompatibilityMigration.SQL, required) {
			t.Fatalf("Rust schema compatibility migration is missing %q", required)
		}
	}
	if strings.Contains(rustCompatibilityMigration.SQL, "inference_jobs") {
		t.Fatal("Rust compatibility migration must not create durable jobs yet")
	}
	durableMigration := migrations[3]
	if !durableMigration.Transactional {
		t.Fatal("Rust durable schema migration must be transactional")
	}
	for _, required := range []string{
		"CREATE TABLE IF NOT EXISTS rust_coord.inference_jobs",
		"CREATE TABLE IF NOT EXISTS rust_coord.inference_attempts",
		"CREATE TABLE IF NOT EXISTS rust_coord.provider_terminals",
		"CREATE TABLE IF NOT EXISTS rust_coord.financial_operations",
		"CREATE TABLE IF NOT EXISTS rust_coord.external_events",
		"CREATE TABLE IF NOT EXISTS rust_coord.outbox",
		"CREATE TABLE IF NOT EXISTS rust_coord.fee_allocations",
		"CREATE TABLE IF NOT EXISTS rust_coord.fee_projection_checkpoints",
		"CREATE TABLE IF NOT EXISTS rust_coord.provider_hard_untrust_epochs",
		"VALUES (2, 4, 4)",
	} {
		if !strings.Contains(durableMigration.SQL, required) {
			t.Fatalf("Rust durable schema migration is missing %q", required)
		}
	}
}

func TestRustDurableMigrationMirrorIsByteIdenticalAndTamperEvident(t *testing.T) {
	canonical, err := os.ReadFile("migrations/000004_rust_durable_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	mirror, err := os.ReadFile("../../coordinator-rs/migrations/000002_rust_durable_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonical, mirror) {
		t.Fatal("Rust durable schema mirror differs from canonical Go migration")
	}

	tampered := bytes.Clone(mirror)
	tampered[len(tampered)/2] ^= 1
	if bytes.Equal(canonical, tampered) {
		t.Fatal("single-byte mirror tamper was not detected")
	}
}

func TestMigrationCatalogRejectsBroadExceptionSwallowing(t *testing.T) {
	err := validateMigrationSQL(migration{
		SQL: `DO $$ BEGIN ALTER TABLE example ADD COLUMN value TEXT;
		      EXCEPTION WHEN OTHERS THEN NULL; END $$;`,
	})
	if err == nil || !strings.Contains(err.Error(), "WHEN OTHERS") {
		t.Fatalf("broad exception guard error = %v", err)
	}
}

func TestSplitSQLStatementsHandlesPostgresQuoting(t *testing.T) {
	sql := `
-- a comment with ;
CREATE TABLE "semi;colon" (value TEXT);
DO $body$
BEGIN
    PERFORM 'quoted;value';
    /* nested ; /* comment ; */ still comment */
END
$body$;
SELECT 'it''s;safe';`

	statements, err := splitSQLStatements(sql)
	if err != nil {
		t.Fatal(err)
	}
	if len(statements) != 3 {
		t.Fatalf("statement count = %d, want 3: %#v", len(statements), statements)
	}
	if !strings.Contains(statements[1], "PERFORM 'quoted;value'") {
		t.Fatalf("PL/pgSQL statement split incorrectly: %q", statements[1])
	}
}

func TestSplitSQLStatementsRejectsUnterminatedInput(t *testing.T) {
	for _, sql := range []string{
		"SELECT 'unterminated",
		`SELECT "unterminated`,
		"DO $$ BEGIN",
		"SELECT 1 /* unterminated",
	} {
		if _, err := splitSQLStatements(sql); err == nil {
			t.Fatalf("splitSQLStatements(%q) succeeded, want error", sql)
		}
	}
}

func TestNewPostgresSourceContainsNoDDLOrDML(t *testing.T) {
	source, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatal(err)
	}
	fileSet := token.NewFileSet()
	file, err := parser.ParseFile(fileSet, "postgres.go", source, 0)
	if err != nil {
		t.Fatal(err)
	}

	var functionSource string
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if !ok || function.Name.Name != "NewPostgres" {
			continue
		}
		start := fileSet.Position(function.Pos()).Offset
		end := fileSet.Position(function.End()).Offset
		functionSource = string(source[start:end])
		break
	}
	if functionSource == "" {
		t.Fatal("NewPostgres source not found")
	}
	forbidden := regexp.MustCompile(`(?i)\b(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE)\b|\.Exec\(|ApplyPostgresMigrations|ActivateCoordinatorOwnership`)
	if match := forbidden.FindString(functionSource); match != "" {
		t.Fatalf("NewPostgres must only connect and check schema compatibility; found %q", match)
	}
	if !strings.Contains(functionSource, "checkSchemaCompatibility") {
		t.Fatal("NewPostgres does not check schema compatibility")
	}
}

func TestServingStoreHasNoMigrationMethods(t *testing.T) {
	source, err := os.ReadFile("postgres.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{
		"func (s *PostgresStore) migrate",
		"ensureProviderEarningsJobIndex",
		"migrations := []string",
	} {
		if strings.Contains(string(source), forbidden) {
			t.Fatalf("serving store still contains migration source %q", forbidden)
		}
	}
}

func TestNewPostgresCallGraphCannotReachMigrationRunner(t *testing.T) {
	fileSet := token.NewFileSet()
	packages, err := parser.ParseDir(fileSet, ".", func(info os.FileInfo) bool {
		return !strings.HasSuffix(info.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatal(err)
	}
	pkg := packages["store"]
	if pkg == nil {
		t.Fatal("store package not found")
	}

	functions := make(map[string]*ast.FuncDecl)
	runnerFunctions := make(map[string]bool)
	for filename, file := range pkg.Files {
		for _, declaration := range file.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok {
				continue
			}
			functions[function.Name.Name] = function
			if filepath.Base(filename) == "migration_runner.go" {
				runnerFunctions[function.Name.Name] = true
			}
		}
	}

	queue := []string{"NewPostgres"}
	visited := make(map[string]bool)
	for len(queue) > 0 {
		name := queue[0]
		queue = queue[1:]
		if visited[name] {
			continue
		}
		visited[name] = true
		if runnerFunctions[name] {
			t.Fatalf("NewPostgres call graph reaches migration runner function %s", name)
		}
		function := functions[name]
		if function == nil {
			continue
		}
		ast.Inspect(function.Body, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			switch called := call.Fun.(type) {
			case *ast.Ident:
				if functions[called.Name] != nil {
					queue = append(queue, called.Name)
				}
			case *ast.SelectorExpr:
				if functions[called.Sel.Name] != nil {
					queue = append(queue, called.Sel.Name)
				}
			}
			return true
		})
	}
}

func TestCoordinatorCommandCannotInvokeMigrationRunner(t *testing.T) {
	fileSet := token.NewFileSet()
	packages, err := parser.ParseDir(fileSet, "../cmd/coordinator", func(info os.FileInfo) bool {
		return !strings.HasSuffix(info.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatal(err)
	}
	pkg := packages["main"]
	if pkg == nil {
		t.Fatal("coordinator command package not found")
	}

	for filename, file := range pkg.Files {
		for _, spec := range file.Imports {
			if strings.Contains(spec.Path.Value, "/cmd/migrate") {
				t.Fatalf("%s imports migration command", filename)
			}
		}
		ast.Inspect(file, func(node ast.Node) bool {
			selector, ok := node.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			pkgName, ok := selector.X.(*ast.Ident)
			if ok && pkgName.Name == "store" && selector.Sel.Name == "ApplyPostgresMigrations" {
				t.Fatalf("%s invokes store.ApplyPostgresMigrations", filename)
			}
			return true
		})
	}
}

func TestDevDeploymentMigratesBeforeCoordinatorRestart(t *testing.T) {
	read := func(path string) string {
		t.Helper()
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return string(content)
	}

	cloudBuild := read("../../deploy/gcp/cloudbuild.yaml")
	migrateAt := strings.Index(cloudBuild, "deploy/gcp/migrate-coordinator.sh")
	tagAt := strings.Index(cloudBuild, "--metadata=DINF_IMAGE_TAG=$SHORT_SHA")
	startupAt := strings.Index(cloudBuild, "--metadata-from-file=startup-script=")
	restartAt := strings.Index(cloudBuild, "systemctl restart d-inference-coordinator")
	if migrateAt < 0 || tagAt < 0 || startupAt < 0 || restartAt < 0 ||
		migrateAt >= tagAt || migrateAt >= startupAt ||
		tagAt >= restartAt || startupAt >= restartAt {
		t.Fatal("Cloud Build must migrate before committing boot metadata and restart")
	}

	migrateScript := read("../../deploy/gcp/migrate-coordinator.sh")
	for _, required := range []string{
		"set -euo pipefail",
		"--entrypoint /usr/local/bin/coordinator-migrate",
		"-lock-timeout=10s",
		"-statement-timeout=30m",
	} {
		if !strings.Contains(migrateScript, required) {
			t.Fatalf("dev migration script is missing %q", required)
		}
	}

	vmStartup := read("../../deploy/gcp/vm-startup.sh")
	migrateAt = strings.Index(vmStartup, "--entrypoint /usr/local/bin/coordinator-migrate")
	serveAt := strings.Index(vmStartup, "exec /usr/bin/docker run")
	if migrateAt < 0 || serveAt < 0 || migrateAt >= serveAt {
		t.Fatal("VM startup must run migrations before launching the coordinator")
	}

	dockerfile := read("../Dockerfile")
	if !strings.Contains(dockerfile, "/usr/local/bin/coordinator-migrate") {
		t.Fatal("coordinator image does not contain the migration command")
	}
}
