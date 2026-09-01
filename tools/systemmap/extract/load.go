// Package extract derives the system map from Go source. It type-checks the
// analyzed service with go/packages, so selector chains, interface
// implementations and embedded fields resolve exactly rather than heuristically.
package extract

import (
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"sort"
	"strings"

	"golang.org/x/tools/go/packages"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// Program is the type-checked service under analysis.
type Program struct {
	Root   string
	Module string
	Fset   *token.FileSet

	pkgs   map[string]*packages.Package // by import path
	order  []string                     // deterministic package iteration order
	decls  map[types.Object]*FuncSym    // function/method object → its declaration
	impls  map[string][]*types.Named    // interface type string → implementations
	schema map[string]*ir.Table         // derived table definitions, memoized
}

// FuncSym is a function or method declaration together with the package whose
// type information describes it.
type FuncSym struct {
	Pkg  *packages.Package
	Recv string
	Name string
	Decl *ast.FuncDecl
}

func (f *FuncSym) key() string {
	if f == nil || f.Pkg == nil {
		return ""
	}
	return f.Pkg.PkgPath + "." + f.Recv + "." + f.Name
}

// Label is the short symbol name cited as evidence, e.g.
// "store.PostgresStore.GetLatestRelease".
func (f *FuncSym) Label() string {
	if f == nil || f.Pkg == nil {
		return ""
	}
	if f.Recv == "" {
		return f.Pkg.Name + "." + f.Name
	}
	return f.Pkg.Name + "." + f.Recv + "." + f.Name
}

// Load type-checks the given package patterns rooted at dir.
func Load(root, module string, patterns []string) (*Program, error) {
	cfg := &packages.Config{
		// No NeedDeps: root packages get syntax and type info, imported
		// packages contribute types through export data. Every package the
		// walker can traverse is inside the analyzed service, so it is a root.
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedCompiledGoFiles |
			packages.NeedImports | packages.NeedTypes | packages.NeedSyntax |
			packages.NeedTypesInfo | packages.NeedModule,
		Dir:   root,
		Tests: false,
	}
	loaded, err := packages.Load(cfg, patterns...)
	if err != nil {
		return nil, fmt.Errorf("load %v: %w", patterns, err)
	}
	p := &Program{
		Root:   root,
		Module: module,
		pkgs:   map[string]*packages.Package{},
		decls:  map[types.Object]*FuncSym{},
		impls:  map[string][]*types.Named{},
	}
	var errs []string
	for _, pkg := range loaded {
		if len(pkg.Errors) > 0 {
			for _, e := range pkg.Errors[:min(2, len(pkg.Errors))] {
				errs = append(errs, fmt.Sprintf("%s: %v", pkg.PkgPath, e))
			}
			continue
		}
		if pkg.TypesInfo == nil || pkg.Fset == nil {
			continue
		}
		p.Fset = pkg.Fset
		p.pkgs[pkg.PkgPath] = pkg
		p.order = append(p.order, pkg.PkgPath)
	}
	if len(p.pkgs) == 0 {
		return nil, fmt.Errorf("no packages type-checked for %v: %s", patterns, strings.Join(errs, "; "))
	}
	if len(errs) > 0 {
		return nil, fmt.Errorf("type errors prevent a trustworthy map: %s", strings.Join(errs, "; "))
	}
	sort.Strings(p.order)
	p.indexDecls()
	return p, nil
}

func (p *Program) indexDecls() {
	for _, path := range p.order {
		pkg := p.pkgs[path]
		for _, file := range pkg.Syntax {
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok {
					continue
				}
				obj := pkg.TypesInfo.Defs[fn.Name]
				if obj == nil {
					continue
				}
				sym := &FuncSym{Pkg: pkg, Name: fn.Name.Name, Decl: fn}
				if fn.Recv != nil && len(fn.Recv.List) > 0 {
					if named := namedOf(pkg.TypesInfo.TypeOf(fn.Recv.List[0].Type)); named != nil {
						sym.Recv = named.Obj().Name()
					}
				}
				p.decls[obj] = sym
			}
		}
	}
}

// Package returns a loaded package by import path.
func (p *Program) Package(importPath string) *packages.Package { return p.pkgs[importPath] }

// Method looks up a method declaration on a named type.
func (p *Program) Method(pkgPath, typeName, method string) *FuncSym {
	pkg := p.pkgs[pkgPath]
	if pkg == nil || pkg.Types == nil {
		return nil
	}
	obj := pkg.Types.Scope().Lookup(typeName)
	if obj == nil {
		return nil
	}
	named, ok := obj.Type().(*types.Named)
	if !ok {
		return nil
	}
	for i := 0; i < named.NumMethods(); i++ {
		if named.Method(i).Name() == method {
			return p.decls[named.Method(i)]
		}
	}
	return nil
}

// DeclOf returns the declaration of a function object, when it was loaded.
func (p *Program) DeclOf(obj types.Object) *FuncSym {
	if obj == nil {
		return nil
	}
	return p.decls[obj]
}

// Implementations returns the loaded named types that implement an interface,
// sorted for determinism.
func (p *Program) Implementations(iface *types.Interface) []*types.Named {
	key := iface.String()
	if cached, ok := p.impls[key]; ok {
		return cached
	}
	var out []*types.Named
	for _, path := range p.order {
		pkg := p.pkgs[path]
		if pkg.Types == nil {
			continue
		}
		scope := pkg.Types.Scope()
		for _, name := range scope.Names() {
			obj, ok := scope.Lookup(name).(*types.TypeName)
			if !ok {
				continue
			}
			named, ok := obj.Type().(*types.Named)
			if !ok {
				continue
			}
			if _, isIface := named.Underlying().(*types.Interface); isIface {
				continue
			}
			if types.Implements(named, iface) || types.Implements(types.NewPointer(named), iface) {
				out = append(out, named)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Obj().Pkg().Path() != out[j].Obj().Pkg().Path() {
			return out[i].Obj().Pkg().Path() < out[j].Obj().Pkg().Path()
		}
		return out[i].Obj().Name() < out[j].Obj().Name()
	})
	p.impls[key] = out
	return out
}

// PosRef renders a repo-relative "file:line" citation.
func (p *Program) PosRef(pos token.Pos) string {
	pt := p.Fset.Position(pos)
	rel := strings.TrimPrefix(strings.TrimPrefix(pt.Filename, p.Root), "/")
	return fmt.Sprintf("%s:%d", rel, pt.Line)
}

// namedOf strips pointers and aliases down to a named type.
func namedOf(t types.Type) *types.Named {
	switch t := t.(type) {
	case *types.Named:
		return t
	case *types.Pointer:
		return namedOf(t.Elem())
	case *types.Slice:
		return namedOf(t.Elem())
	case *types.Array:
		return namedOf(t.Elem())
	case *types.Map:
		return namedOf(t.Elem())
	case *types.Chan:
		return namedOf(t.Elem())
	case *types.Alias:
		return namedOf(types.Unalias(t))
	}
	return nil
}

// typeKey renders "pkgPath:TypeName" for a type, used to look up overlay
// mappings.
func typeKey(t types.Type) (string, string, bool) {
	named := namedOf(t)
	if named == nil || named.Obj().Pkg() == nil {
		return "", "", false
	}
	return named.Obj().Pkg().Path(), named.Obj().Name(), true
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
