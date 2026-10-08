package postgres_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"testing"
)

// pgx's graceful Close may block while writing Terminate. Keep the exact
// migration context at this boundary rather than detaching its deadline.
func TestConcurrentIndexClosePreservesMigrationContext(t *testing.T) {
	path := filepath.Join("..", "..", "..", "store", "postgres", "migration_indexes.go")
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if !ok || function.Name.Name != "ensureConcurrentIndex" {
			continue
		}
		for _, statement := range function.Body.List {
			deferred, ok := statement.(*ast.DeferStmt)
			if !ok {
				continue
			}
			method, ok := deferred.Call.Fun.(*ast.SelectorExpr)
			if !ok || method.Sel.Name != "Close" {
				continue
			}
			if receiver, ok := method.X.(*ast.Ident); !ok || receiver.Name != "conn" {
				continue
			}
			if len(deferred.Call.Args) != 1 {
				t.Fatal("migration connection Close must receive its context")
			}
			if ctx, ok := deferred.Call.Args[0].(*ast.Ident); !ok || ctx.Name != "ctx" {
				t.Fatal("migration connection Close must preserve the original context and deadline")
			}
			return
		}
	}
	t.Fatal("missing deferred migration connection Close")
}
