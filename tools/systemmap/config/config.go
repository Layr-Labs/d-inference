// Package config loads the curated overlay: the parts of the system map that
// source cannot state on its own.
//
// The split is deliberate. Routes, middleware chains, authorization gates,
// dependency nodes, R/W/RW modes and citations are all derived from source and
// never written here. The overlay supplies only what a compiler cannot know:
// how state groups into named nodes, what those nodes are called, which actor
// calls an endpoint, and the prose. Anything the extractor finds that the
// overlay does not explain is reported as drift rather than silently dropped.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// Config is the parsed overlay.
type Config struct {
	Service      ServiceConfig              `json:"service"`
	Repo         RepoConfig                 `json:"repo"`
	Clusters     map[string]ir.Cluster      `json:"clusters"`
	Categories   map[string]ir.Category     `json:"categories"`
	CategoryDocs map[string]json.RawMessage `json:"categoryDocs"`
	Labels       map[string]string          `json:"labels"`
	DepDocs      map[string]json.RawMessage `json:"depDocs"`
	Roles        []json.RawMessage          `json:"roles"`
	Credentials  []json.RawMessage          `json:"credentials"`
	Cache        map[string]json.RawMessage `json:"cacheSemantics"`
	Namespaces   []NamespaceRule            `json:"namespaces"`
	AuthRules    []AuthRule                 `json:"authRules"`
	Gates        []string                   `json:"gates"`
	GateDepthN   int                        `json:"gateDepth"`
	Routes       map[string]RouteOverlay    `json:"routes"`
	Deps         DepsConfig                 `json:"deps"`

	knownTables map[string]bool
	module      string
}

type ServiceConfig struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Language string `json:"language"`
	Root     string `json:"root"`

	// RouteTable locates the function that registers the service's routes, so
	// the extractor reads the real table instead of guessing at handler names.
	RouteTable RouteTableConfig `json:"routeTable"`
}

// RouteTableConfig identifies the route-registration method:
// (*api.Server).routes registering onto its `mux` field.
type RouteTableConfig struct {
	Package string `json:"package"`
	Type    string `json:"type"`
	Method  string `json:"method"`
	Mux     string `json:"mux"`
}

// ImportPath resolves a repo-relative package directory to its import path.
func (c *Config) ImportPath(rel string) string {
	if c.module == "" || strings.HasPrefix(rel, c.module) {
		return rel
	}
	return c.module + "/" + strings.Trim(rel, "/")
}

type RepoConfig struct {
	Remote string `json:"remote"`
}

// NamespaceRule assigns a namespace by exact route key or path prefix. Rules are
// evaluated in order, so the most specific must come first.
type NamespaceRule struct {
	Exact     string   `json:"exact,omitempty"`
	Prefix    string   `json:"prefix,omitempty"`
	Methods   []string `json:"methods,omitempty"`
	Namespace string   `json:"namespace"`
}

// AuthRule maps evidence about a route — its middleware chain, the
// authorization gates its reachable code calls, and its handler name — to an
// auth class. The first matching rule wins; a rule with no conditions is the
// fallback.
type AuthRule struct {
	Middleware    []string `json:"middleware,omitempty"`
	NotMiddleware []string `json:"notMiddleware,omitempty"`
	AnyGate       []string `json:"anyGate,omitempty"`
	NoGate        []string `json:"noGate,omitempty"`
	Handler       string   `json:"handler,omitempty"`
	Auth          string   `json:"auth"`
	Detail        string   `json:"detail"`
}

// RouteOverlay is the curated prose for one route, keyed "METHOD /path".
type RouteOverlay struct {
	Description string   `json:"description"`
	Details     string   `json:"details,omitempty"`
	Callers     []string `json:"callers,omitempty"`
}

// DepsConfig declares the node taxonomy and how source constructs map onto it.
type DepsConfig struct {
	Analyze        []string                     `json:"analyze"`
	Traverse       []string                     `json:"traverse"`
	Inherit        []string                     `json:"inherit"`
	PreferImpl     []string                     `json:"preferImpl"`
	Fields         map[string]string            `json:"fields"`
	Functions      map[string]string            `json:"functions"`
	Strict         []string                     `json:"strict"`
	PackageDefault map[string]string            `json:"packageDefault"`
	Types          map[string]string            `json:"types"`
	Hosts          map[string]string            `json:"hosts"`
	Endpoints      map[string]map[string]string `json:"endpoints"`
	Messages       map[string]map[string]string `json:"messages"`

	traverse map[string]bool
	inherit  map[string]bool
	strict   map[string]bool
}

// Load reads and validates the overlay. Unknown fields are an error: a typo in
// a key would otherwise silently disable a whole mapping table.
func Load(path, module string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{module: module}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(cfg); err != nil {
		return nil, fmt.Errorf("overlay %s: %w", path, err)
	}
	cfg.Deps.traverse = index(cfg.Deps.Traverse)
	cfg.Deps.inherit = index(cfg.Deps.Inherit)
	cfg.Deps.strict = index(cfg.Deps.Strict)
	if cfg.Deps.Hosts == nil {
		cfg.Deps.Hosts = map[string]string{}
	}
	if cfg.Deps.Types == nil {
		cfg.Deps.Types = map[string]string{}
	}
	return cfg, nil
}

func index(list []string) map[string]bool {
	out := make(map[string]bool, len(list))
	for _, s := range list {
		out[s] = true
	}
	return out
}

// Module returns the Go module path the analyzed service lives in.
func (c *Config) Module() string { return c.module }

// SetKnownTables records the tables the schema actually declares, so SQL
// matches can be validated instead of trusted.
func (c *Config) SetKnownTables(tables map[string]bool) { c.knownTables = tables }

// KnownTable reports whether a table name appears in a CREATE TABLE statement.
func (c *Config) KnownTable(name string) bool { return c.knownTables[name] }

// Rel converts a Go import path to the repo-relative directory used as the
// overlay key ("coordinator/store").
func (c *Config) Rel(importPath string) string {
	if c.module != "" && strings.HasPrefix(importPath, c.module) {
		return strings.TrimPrefix(strings.TrimPrefix(importPath, c.module), "/")
	}
	return importPath
}

// Analyze returns the package patterns to type-check.
func (c *Config) AnalyzePatterns() []string { return c.Deps.Analyze }

// Traverse reports whether the walker may follow calls into a package.
func (c *Config) Traverse(importPath string) bool { return c.Deps.traverse[c.Rel(importPath)] }

// Inherits reports whether nested state inside a package's structs should
// inherit the node of the field it was reached through.
func (c *Config) Inherits(importPath string) bool { return c.Deps.inherit[c.Rel(importPath)] }

// PreferImpl reports whether a concrete type is the preferred implementation of
// an interface (the Postgres store over the in-memory one, so SQL evidence is
// recovered).
func (c *Config) PreferImpl(typeName string) bool {
	for _, want := range c.Deps.PreferImpl {
		if strings.Contains(typeName, want) {
			return true
		}
	}
	return false
}

// FieldSource says how a field's node was decided. The distinction matters
// because "the map names this state" and "a package-wide default absorbed it"
// look identical in the finished picture: only the first is a claim someone made.
type FieldSource int

const (
	// FieldUnmapped: nothing in the overlay covers this field.
	FieldUnmapped FieldSource = iota
	// FieldExplicit: a `deps.fields` key names this field (or its struct, or the
	// field name across the package) — including the "@skip"/"@sql" sentinels,
	// which are deliberate statements that it is not a node.
	FieldExplicit
	// FieldDefault: only `deps.packageDefault` covered it.
	FieldDefault
)

// FieldNode maps a struct field to its dependency node. "@skip" and "@sql"
// resolve to no node: the first is uninteresting state, the second contributes
// only through the SQL its methods run. The source reports how the answer was
// reached, so unmapped state can be drift and defaulted state can be audited.
func (c *Config) FieldNode(importPath, structName, field string) (string, FieldSource) {
	rel := c.Rel(importPath)
	for _, key := range []string{
		rel + ":" + structName + "." + field,
		structName + "." + field,
		rel + ":" + structName + ".*",
		rel + ":*." + field,
	} {
		if node, ok := c.Deps.Fields[key]; ok {
			return sentinel(node), FieldExplicit
		}
	}
	// A strict struct gets no package fallback: every one of its fields must be
	// declared, so adding coordinator state is drift until the map explains it.
	if c.Deps.strict[rel+":"+structName] {
		return "", FieldUnmapped
	}
	if node, ok := c.Deps.PackageDefault[rel]; ok {
		return sentinel(node), FieldDefault
	}
	return "", FieldUnmapped
}

// TypeDeclared reports whether `deps.types` names this type outright. A type the
// overlay has decided about — even decided to skip — is not silently absorbed
// state, which is what the concurrent-state check turns on.
func (c *Config) TypeDeclared(importPath, typeName string) bool {
	_, ok := c.Deps.Types[c.Rel(importPath)+":"+typeName]
	return ok
}

// StructDeclared reports whether the overlay has decided anything about a struct:
// a `deps.types` node for it, or any `deps.fields` key naming one of its fields
// (including the `Struct.*` wildcard). Either way a person has looked at it, which
// is all the concurrent-state check asks for. The fields table is scanned rather
// than indexed so the answer always reflects the live map.
func (c *Config) StructDeclared(importPath, structName string) bool {
	if c.TypeDeclared(importPath, structName) {
		return true
	}
	qualified := c.Rel(importPath) + ":" + structName + "."
	for key := range c.Deps.Fields {
		if strings.HasPrefix(key, qualified) || strings.HasPrefix(key, structName+".") {
			return true
		}
	}
	return false
}

// FuncNode maps a function or method to the surface it is the code for. Some
// boundaries have no literal and no field to attribute: the media fetcher issues
// a request to whatever URL the consumer supplied, so the outbound call itself is
// the evidence.
func (c *Config) FuncNode(importPath, recv, name string) (string, bool) {
	key := c.Rel(importPath) + ":" + name
	if recv != "" {
		key = c.Rel(importPath) + ":" + recv + "." + name
	}
	node, ok := c.Deps.Functions[key]
	if !ok {
		return "", false
	}
	return sentinel(node), true
}

// TypeNode maps a type (e.g. the provider WebSocket connection) to a node, so
// surfaces that are types rather than fields still appear.
func (c *Config) TypeNode(importPath, typeName string) (string, bool) {
	node, ok := c.Deps.Types[c.Rel(importPath)+":"+typeName]
	if !ok {
		return "", false
	}
	return sentinel(node), true
}

// HostNode maps an external hostname found in a URL literal to a node. "@skip"
// covers our own public hostnames, which are not external dependencies.
func (c *Config) HostNode(host string) (string, bool) {
	node, ok := c.Deps.Hosts[host]
	if !ok {
		return "", false
	}
	return sentinel(node), true
}

// EndpointNode maps a client-side endpoint path literal (as written in the MDM
// or prompt-sidecar client) to the node for that remote surface.
func (c *Config) EndpointNode(importPath, literal string) (string, bool) {
	table, ok := c.Deps.Endpoints[c.Rel(importPath)]
	if !ok {
		return "", false
	}
	node, ok := table[literal]
	return node, ok
}

// MessageNode maps a protocol message-type constant to the provider-socket node
// it belongs to.
func (c *Config) MessageNode(importPath, ident string) (string, bool) {
	table, ok := c.Deps.Messages[c.Rel(importPath)]
	if !ok {
		return "", false
	}
	node, ok := table[ident]
	return node, ok
}

// GateNames returns the authorization gates worth detecting.
func (c *Config) GateNames() map[string]bool { return index(c.Gates) }

// GateDepth bounds how far from a handler a gate call still counts as that
// route's authorization. A gate is called by the handler or by a helper it calls
// directly; anything deeper is incidental and would misclassify the route.
func (c *Config) GateDepth() int {
	if c.GateDepthN <= 0 {
		return 2
	}
	return c.GateDepthN
}

func sentinel(node string) string {
	if strings.HasPrefix(node, "@") {
		return ""
	}
	return node
}

// Namespace assigns a route to a namespace. The bool reports whether a rule
// matched.
func (c *Config) Namespace(method, path string) (string, bool) {
	for _, rule := range c.Namespaces {
		if rule.Exact != "" {
			if rule.Exact == method+" "+path || rule.Exact == path {
				return rule.Namespace, true
			}
			continue
		}
		if rule.Prefix == "" || !strings.HasPrefix(path, rule.Prefix) {
			continue
		}
		if len(rule.Methods) > 0 && !contains(rule.Methods, method) {
			continue
		}
		return rule.Namespace, true
	}
	return "Unclassified", false
}

// Auth classifies a route from its middleware, gates and handler name.
func (c *Config) Auth(middleware, gates []string, handler string) (string, string, bool) {
	for _, rule := range c.AuthRules {
		if !containsAll(middleware, rule.Middleware) {
			continue
		}
		if containsAny(middleware, rule.NotMiddleware) || containsAny(gates, rule.NoGate) {
			continue
		}
		if len(rule.AnyGate) > 0 && !containsAny(gates, rule.AnyGate) {
			continue
		}
		if rule.Handler != "" && rule.Handler != handler {
			continue
		}
		return rule.Auth, rule.Detail, true
	}
	return "Unclassified", "", false
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func containsAll(have, want []string) bool {
	for _, w := range want {
		if !contains(have, w) {
			return false
		}
	}
	return true
}

func containsAny(have, want []string) bool {
	for _, w := range want {
		if contains(have, w) {
			return true
		}
	}
	return false
}
