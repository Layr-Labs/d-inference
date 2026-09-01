package extract

import (
	"go/ast"
	"regexp"
	"sort"
	"strings"
)

// TableAccess is one table named by a SQL statement, with the mode the
// statement's verb implies.
type TableAccess struct {
	Table string
	Mode  string // "R" or "W"
}

var (
	reIdent      = `((?:"[a-z_][a-z0-9_$]*"|[a-z_][a-z0-9_$]*)(?:\.(?:"[a-z_][a-z0-9_$]*"|[a-z_][a-z0-9_$]*))?)`
	reInsert     = regexp.MustCompile(`insert\s+into\s+` + reIdent)
	reUpdate     = regexp.MustCompile(`update\s+(?:only\s+)?` + reIdent)
	reDelete     = regexp.MustCompile(`delete\s+from\s+(?:only\s+)?` + reIdent)
	reCreate     = regexp.MustCompile(`create\s+(?:unlogged\s+|temp\s+|temporary\s+)?table\s+(?:if\s+not\s+exists\s+)?` + reIdent)
	reAlter      = regexp.MustCompile(`alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?` + reIdent)
	reDrop       = regexp.MustCompile(`drop\s+table\s+(?:if\s+exists\s+)?` + reIdent)
	reTruncate   = regexp.MustCompile(`truncate\s+(?:table\s+)?` + reIdent)
	reFrom       = regexp.MustCompile(`from\s+(?:only\s+)?` + reIdent)
	reJoin       = regexp.MustCompile(`join\s+(?:only\s+)?` + reIdent)
	reUsing      = regexp.MustCompile(`\busing\s+` + reIdent)
	reCTE        = regexp.MustCompile(`(?:with|,)\s+(?:recursive\s+)?([a-z_][a-z0-9_$]*)\s+as\s*\(`)
	reWhitespace = regexp.MustCompile(`\s+`)

	writeMatchers = []*regexp.Regexp{reInsert, reUpdate, reDelete, reCreate, reAlter, reDrop, reTruncate, reUsing}
	readMatchers  = []*regexp.Regexp{reFrom, reJoin}

	// SQL keywords that can legally follow FROM/JOIN without naming a table.
	sqlNoise = map[string]bool{
		"select": true, "values": true, "only": true, "lateral": true, "unnest": true,
		"generate_series": true, "dual": true, "set": true, "where": true,
	}
)

// sqlForms is the grammar test for "is this literal a statement": a leading verb
// plus the clause that verb cannot legally appear without. The verb alone is not
// enough — the coordinator is full of English that starts with one ("update
// capabilities", "delete from the fleet"), and a prose match would invent a
// table named after the next word.
var sqlForms = []struct {
	verb     *regexp.Regexp
	requires *regexp.Regexp // nil when the verb is unambiguous on its own
}{
	{regexp.MustCompile(`^insert\s`), regexp.MustCompile(`\binto\s+` + reIdent)},
	{regexp.MustCompile(`^update\s`), regexp.MustCompile(`\bset\s`)},
	{regexp.MustCompile(`^delete\s`), regexp.MustCompile(`^delete\s+from\s+(?:only\s+)?` + reIdent)},
	{regexp.MustCompile(`^select\s`), regexp.MustCompile(`\bfrom\s|\(`)},
	{regexp.MustCompile(`^with\s`), regexp.MustCompile(`\bas\s*\(`)},
	{regexp.MustCompile(`^create\s+(?:unlogged\s+|temp\s+|temporary\s+|unique\s+)?(?:table|index)\s`), nil},
	{regexp.MustCompile(`^alter\s+table\s`), nil},
	{regexp.MustCompile(`^drop\s+(?:table|index)\s`), nil},
	{regexp.MustCompile(`^truncate\s`), regexp.MustCompile(`^truncate\s+(?:table\s+)?` + reIdent)},
	{regexp.MustCompile(`^do\s+\$\$`), nil},
}

// IsSQL reports whether a string literal is a SQL statement.
func IsSQL(s string) bool {
	if len(s) < 12 || !strings.ContainsAny(s, " \t\n") {
		return false
	}
	norm := normalizeSQL(s)
	for _, form := range sqlForms {
		if !form.verb.MatchString(norm) {
			continue
		}
		return form.requires == nil || form.requires.MatchString(norm)
	}
	return false
}

func normalizeSQL(s string) string {
	return strings.ToLower(strings.TrimSpace(reWhitespace.ReplaceAllString(s, " ")))
}

// Tables classifies a SQL statement into per-table read and write accesses.
//
// Writes are matched first and masked out of the statement, so the `FROM` of an
// `INSERT ... SELECT ... FROM other` still reads `other` while the insert target
// stays a write and is not double-counted as a read.
func Tables(sql string) []TableAccess {
	norm := normalizeSQL(sql)
	ctes := map[string]bool{}
	for _, m := range reCTE.FindAllStringSubmatch(norm, -1) {
		ctes[m[1]] = true
	}
	modes := map[string]string{}
	add := func(name, mode string) {
		name = cleanIdent(name)
		if name == "" || ctes[name] || sqlNoise[name] {
			return
		}
		switch {
		case modes[name] == "" || modes[name] == mode:
			modes[name] = mode
		default:
			modes[name] = "RW"
		}
	}
	base := string(maskKeywordCalls([]byte(norm)))
	masked := []byte(base)
	for _, re := range writeMatchers {
		for _, loc := range re.FindAllStringSubmatchIndex(base, -1) {
			add(base[loc[2]:loc[3]], "W")
			for i := loc[0]; i < loc[1]; i++ {
				masked[i] = ' '
			}
		}
	}
	for _, re := range readMatchers {
		for _, m := range re.FindAllStringSubmatch(string(masked), -1) {
			add(m[1], "R")
		}
	}
	out := make([]TableAccess, 0, len(modes))
	for name, mode := range modes {
		out = append(out, TableAccess{Table: name, Mode: mode})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Table < out[j].Table })
	return out
}

// keywordCalls are the SQL functions whose arguments are separated by keywords
// rather than commas. They are the complete set in which FROM/IN/FOR/PLACING
// appear without introducing a table — `extract(epoch FROM created_at)` would
// otherwise be read as a table named `created_at`.
var keywordCalls = []string{"extract", "substring", "trim", "overlay", "position"}

// maskKeywordCalls blanks the argument list of each keyword-argument call,
// tracking nesting so a call containing parentheses is masked in full.
func maskKeywordCalls(b []byte) []byte {
	for _, name := range keywordCalls {
		for at := 0; at < len(b); {
			j := strings.Index(string(b[at:]), name+"(")
			if j < 0 {
				break
			}
			start := at + j
			open := start + len(name)
			at = open + 1
			if start > 0 && isIdentByte(b[start-1]) {
				continue // the tail of a longer identifier
			}
			depth := 0
			for k := open; k < len(b); k++ {
				switch b[k] {
				case '(':
					depth++
				case ')':
					depth--
				}
				if depth == 0 {
					at = k
					break
				}
				if k > open {
					b[k] = ' '
				}
			}
		}
	}
	return b
}

func isIdentByte(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9'
}

// cleanIdent strips quoting and a schema qualifier.
func cleanIdent(name string) string {
	name = strings.ReplaceAll(name, `"`, "")
	if i := strings.LastIndex(name, "."); i >= 0 {
		name = name[i+1:]
	}
	return name
}

// StringLiterals collects every string literal a package declares, so an overlay
// claim about a remote endpoint path can be checked against source even when no
// endpoint reaches it (the MDM command surfaces are driven by the background
// verification scheduler).
func (p *Program) StringLiterals(importPath string) map[string]bool {
	out := map[string]bool{}
	pkg := p.pkgs[importPath]
	if pkg == nil {
		return out
	}
	for _, file := range pkg.Syntax {
		ast.Inspect(file, func(n ast.Node) bool {
			if lit, ok := n.(*ast.BasicLit); ok {
				if s, ok := stringLit(lit); ok {
					out[s] = true
				}
			}
			return true
		})
	}
	return out
}
