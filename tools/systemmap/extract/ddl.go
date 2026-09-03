package extract

// The lexical half of schema derivation: how a DDL string is chopped into
// statements, columns and constraints. It is deliberately separate from
// schema.go, which decides what those pieces mean for the map — this file knows
// only about parens, quotes, commas and indentation.

import (
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// statementAt returns the single SQL statement beginning at idx: everything up to
// the first semicolon at paren depth zero, or the end of the literal.
func statementAt(text string, idx int) string {
	depth := 0
	for i := idx; i < len(text); i++ {
		switch text[i] {
		case '\'':
			for i++; i < len(text); i++ {
				if text[i] == '\'' {
					break
				}
			}
		case '(':
			depth++
		case ')':
			depth--
		case ';':
			if depth == 0 {
				return dedent(strings.TrimSpace(text[idx : i+1]))
			}
		}
	}
	return dedent(strings.TrimSpace(text[idx:]))
}

// balanced returns the text between a '(' and its matching ')', plus the index
// just past that ')'. Quoted strings and dollar-quoted bodies are skipped so a
// paren inside a DEFAULT literal cannot end the column list early.
func balanced(text string, open int) (string, int) {
	depth := 0
	for i := open; i < len(text); i++ {
		switch text[i] {
		case '\'':
			for i++; i < len(text); i++ {
				if text[i] == '\'' {
					break
				}
			}
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return text[open+1 : i], i + 1
			}
		}
	}
	return text[min(open+1, len(text)):], len(text)
}

// parseColumns splits a CREATE TABLE body into columns and table-level
// constraints. Splitting is depth-aware, so `NUMERIC(10, 2)` and a multi-column
// `PRIMARY KEY (a, b)` stay in one piece.
func parseColumns(body string, site func(int) string) ([]ir.Column, []ir.Constraint) {
	var cols []ir.Column
	var cons []ir.Constraint
	for _, part := range splitTopLevel(body) {
		text := strings.TrimSpace(part.text)
		if text == "" {
			continue
		}
		// `UNIQUE (a, b)` and `UNIQUE(a, b)` are the same constraint; without
		// cutting at the paren the second form parses as a column named
		// "unique(a, b)".
		head, _, _ := strings.Cut(strings.ToLower(firstWord(text)), "(")
		if ddlConstraintHeads[head] {
			cons = append(cons, ir.Constraint{Text: collapse(text), Site: site(part.idx)})
			continue
		}
		fields := tokenize(text)
		if len(fields) == 0 {
			continue
		}
		col := ir.Column{Name: cleanIdent(strings.ToLower(fields[0])), Site: site(part.idx)}
		col.Type, col.Extra = splitType(strings.Join(fields[1:], " "))
		cols = append(cols, col)
	}
	return cols, cons
}

// splitType separates a column's type from the rest of its definition
// (nullability, default, inline constraints), keeping multi-word types whole.
func splitType(rest string) (string, string) {
	fields := tokenize(rest)
	if len(fields) == 0 {
		return "", ""
	}
	n := 1
	for n < len(fields) && ddlTypeTail[strings.ToLower(fields[n])] {
		n++
	}
	return collapse(strings.Join(fields[:n], " ")), collapse(strings.Join(fields[n:], " "))
}

type ddlPart struct {
	text string
	idx  int
}

// splitTopLevel splits on commas at paren depth zero, remembering where each
// piece started so it can be cited.
func splitTopLevel(body string) []ddlPart {
	var out []ddlPart
	depth, start := 0, 0
	for i := 0; i < len(body); i++ {
		switch body[i] {
		case '\'':
			for i++; i < len(body); i++ {
				if body[i] == '\'' {
					break
				}
			}
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, ddlPart{text: body[start:i], idx: start})
				start = i + 1
			}
		}
	}
	if start < len(body) {
		out = append(out, ddlPart{text: body[start:], idx: start})
	}
	for i := range out {
		trimmed := strings.TrimLeft(out[i].text, " \t\r\n")
		out[i].idx += len(out[i].text) - len(trimmed)
		out[i].text = trimmed
	}
	return out
}

// tokenize splits on whitespace at paren depth zero.
func tokenize(s string) []string {
	var out []string
	depth, start := 0, -1
	flush := func(end int) {
		if start >= 0 {
			out = append(out, s[start:end])
			start = -1
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '(':
			depth++
		case c == ')':
			depth--
		case depth == 0 && (c == ' ' || c == '\t' || c == '\n' || c == '\r'):
			flush(i)
			continue
		}
		if start < 0 {
			start = i
		}
	}
	flush(len(s))
	return out
}

func firstWord(s string) string {
	if fields := tokenize(s); len(fields) > 0 {
		return fields[0]
	}
	return ""
}

func collapse(s string) string { return strings.TrimSpace(reWhitespace.ReplaceAllString(s, " ")) }

// dedent removes the Go source indentation a DDL literal inherited, so the
// statement reads as SQL. Only leading whitespace changes.
func dedent(s string) string {
	lines := strings.Split(s, "\n")
	if len(lines) < 2 {
		return s
	}
	prefix := -1
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		n := len(line) - len(strings.TrimLeft(line, "\t "))
		if prefix < 0 || n < prefix {
			prefix = n
		}
	}
	if prefix <= 0 {
		return s
	}
	for i := 1; i < len(lines); i++ {
		if len(lines[i]) >= prefix {
			lines[i] = lines[i][prefix:]
		} else {
			lines[i] = strings.TrimLeft(lines[i], "\t ")
		}
	}
	return strings.Join(lines, "\n")
}
