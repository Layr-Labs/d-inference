package main

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
)

type routeContract struct {
	Pattern     string `json:"pattern"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	Handler     string `json:"handler"`
	Auth        string `json:"auth"`
	Area        string `json:"area"`
	SideEffects string `json:"side_effects"`
	RustOwner   string `json:"rust_owner"`
	Pilot       bool   `json:"pilot"`
	Disposition string `json:"disposition"`
}

type routeContractFile struct {
	SchemaVersion int             `json:"schema_version"`
	Source        string          `json:"source"`
	Routes        []routeContract `json:"routes"`
}

func generateRoutes(root string) (map[string][]byte, error) {
	const source = "coordinator/api/server.go"
	routes, err := parseRoutes(root + "/" + source)
	if err != nil {
		return nil, err
	}
	contract, err := json.MarshalIndent(routeContractFile{
		SchemaVersion: 1,
		Source:        source,
		Routes:        routes,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal route contract: %w", err)
	}

	return map[string][]byte{
		"tests/contracts/http/routes.json":           contract,
		"docs/reference/coordinator-route-matrix.md": []byte(renderRouteMatrix(routes)),
	}, nil
}

func parseRoutes(path string) ([]routeContract, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		return nil, fmt.Errorf("parse routes: %w", err)
	}

	var routesFn *ast.FuncDecl
	for _, declaration := range file.Decls {
		fn, ok := declaration.(*ast.FuncDecl)
		if ok && fn.Name.Name == "routes" {
			routesFn = fn
			break
		}
	}
	if routesFn == nil {
		return nil, fmt.Errorf("routes function not found in %s", path)
	}

	var routes []routeContract
	ast.Inspect(routesFn.Body, func(node ast.Node) bool {
		call, ok := node.(*ast.CallExpr)
		if !ok || len(call.Args) != 2 || !isHandleFunc(call.Fun) {
			return true
		}
		literal, ok := call.Args[0].(*ast.BasicLit)
		if !ok || literal.Kind != token.STRING {
			return true
		}
		pattern, err := strconv.Unquote(literal.Value)
		if err != nil {
			return true
		}
		method, routePath := splitRoutePattern(pattern)
		handler := renderExpression(call.Args[1])
		routes = append(routes, classifyRoute(pattern, method, routePath, handler))
		return true
	})
	if len(routes) == 0 {
		return nil, fmt.Errorf("no routes found in %s", path)
	}
	return routes, nil
}

func isHandleFunc(expression ast.Expr) bool {
	selector, ok := expression.(*ast.SelectorExpr)
	return ok && selector.Sel.Name == "HandleFunc"
}

func renderExpression(expression ast.Expr) string {
	switch value := expression.(type) {
	case *ast.SelectorExpr:
		return value.Sel.Name
	case *ast.Ident:
		return value.Name
	case *ast.CallExpr:
		name := renderExpression(value.Fun)
		args := make([]string, 0, len(value.Args))
		for _, arg := range value.Args {
			args = append(args, renderExpression(arg))
		}
		return name + "(" + strings.Join(args, ",") + ")"
	case *ast.FuncLit:
		return "inline"
	default:
		return fmt.Sprintf("%T", expression)
	}
}

func splitRoutePattern(pattern string) (string, string) {
	method, path, ok := strings.Cut(pattern, " ")
	if !ok {
		return "ANY", pattern
	}
	return method, path
}

func classifyRoute(pattern, method, path, handler string) routeContract {
	route := routeContract{
		Pattern:     pattern,
		Method:      method,
		Path:        path,
		Handler:     handler,
		Auth:        routeAuth(path, handler),
		Area:        routeArea(path),
		SideEffects: routeSideEffects(method, path),
		RustOwner:   "full-surface adapter",
		Disposition: "implement",
	}
	switch path {
	case "/health", "/readyz", "/ws/provider", "/v1/encryption-key",
		"/v1/models", "/v1/models/{id...}", "/v1/chat/completions",
		"/v1/models/catalog", "/v1/models/catalog/manifest/", "/v1/models/catalog/":
		route.Pilot = true
		route.RustOwner = "pilot adapter"
	}
	if path == "/v1/" {
		route.RustOwner = "compatibility catch-all"
	}
	return route
}

func routeAuth(path, handler string) string {
	switch {
	case path == "/v1/admin/auth/init" || path == "/v1/admin/auth/verify":
		return "public"
	case strings.HasPrefix(path, "/v1/admin/models/"):
		return "publishing_key_or_admin_key"
	case path == "/v1/admin/state-export":
		return "admin_key_only"
	case path == "/v1/admin/releases" || path == "/v1/admin/metrics" ||
		path == "/v1/admin/base-rewards" || path == "/v1/admin/utilization" ||
		path == "/v1/admin/routes" || path == "/v1/admin/routes/export" ||
		path == "/v1/admin/rejections" || path == "/v1/admin/rejections/export":
		return "admin_key_only"
	case strings.HasPrefix(path, "/v1/admin/"):
		return "admin_key_or_privy_admin"
	case strings.Contains(handler, "requirePrivyAuth"):
		return "privy_jwt"
	case strings.Contains(handler, "requireAuth"):
		return "api_key_or_privy"
	case path == "/ws/provider":
		return "provider_registration"
	case path == "/v1/billing/stripe/webhook" || path == "/v1/billing/stripe/connect/webhook":
		return "stripe_signature"
	case path == "/v1/mdm/webhook":
		return "mdm_command_and_secret"
	case path == "/v1/releases":
		return "release_key"
	case path == "/v1/telemetry/events":
		return "optional_provider_token_privy_api_key_or_anonymous"
	default:
		return "public"
	}
}

func routeArea(path string) string {
	switch {
	case path == "/health" || path == "/readyz":
		return "operations"
	case path == "/ws/provider":
		return "provider_session"
	case strings.Contains(path, "/chat/") || path == "/v1/responses" ||
		path == "/v1/completions" || path == "/v1/messages":
		return "inference"
	case strings.Contains(path, "/models"):
		return "models"
	case strings.Contains(path, "/billing") || strings.Contains(path, "/payments") ||
		strings.Contains(path, "/pricing") || strings.Contains(path, "/referral") ||
		strings.Contains(path, "/invite") || strings.Contains(path, "/reward") ||
		strings.Contains(path, "/credit") || strings.Contains(path, "earnings"):
		return "billing"
	case strings.Contains(path, "/keys") || path == "/v1/key" ||
		strings.Contains(path, "/device/") || strings.Contains(path, "/auth/") ||
		strings.HasPrefix(path, "/v1/me/"):
		return "identity"
	case strings.Contains(path, "/mdm") || strings.Contains(path, "/enroll") ||
		strings.Contains(path, "/attestation") || strings.Contains(path, "/runtime/"):
		return "trust"
	case strings.Contains(path, "/admin"):
		return "admin"
	case strings.Contains(path, "/telemetry") || strings.Contains(path, "/log-report"):
		return "telemetry"
	default:
		return "public_read"
	}
}

func routeSideEffects(method, path string) string {
	switch {
	case path == "/ws/provider":
		return "live_session"
	case strings.Contains(path, "/webhook"):
		return "external_event"
	case method == "GET":
		return "read"
	case method == "ANY":
		return "none"
	default:
		return "write"
	}
}

func renderRouteMatrix(routes []routeContract) string {
	var out strings.Builder
	out.WriteString("# Coordinator Route Matrix\n\n")
	out.WriteString("Generated by `make contracts-update` from `coordinator/api/server.go`; do not edit by hand.\n\n")
	out.WriteString("`Disposition=implement` means Rust must own the route before Go retirement. Pilot routes are the isolated Milestone 3 surface; all others are Milestone 6 parity work.\n\n")
	out.WriteString("| Method | Path | Handler chain | Auth | Area | Effects | Rust owner | Pilot | Disposition |\n")
	out.WriteString("|---|---|---|---|---|---|---|---:|---|\n")
	for _, route := range routes {
		fmt.Fprintf(&out, "| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | %s | %t | %s |\n",
			route.Method,
			strings.ReplaceAll(route.Path, "|", "\\|"),
			strings.ReplaceAll(route.Handler, "|", "\\|"),
			route.Auth,
			route.Area,
			route.SideEffects,
			route.RustOwner,
			route.Pilot,
			route.Disposition,
		)
	}
	return out.String()
}
