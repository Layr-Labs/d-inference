package extract

// The lexical half of schema derivation: how a DDL string is chopped into
// statements, columns and constraints. It is deliberately separate from
// schema.go, which decides what those pieces mean for the map — this file knows
// only about parens, quotes, commas and indentation.

import (
	"strings"

	"github.com/eigeninference/d-inference/tools/systemmap/ir"
)

// maskSQLComments blanks every SQL comment in a literal, keeping the text the same
// length so every index derived from it still cites the same line.
//
// A comment is not a declaration, and the DDL here is read by regex rather than
// parsed, so `-- references users(id)` beside a column would otherwise mint a
// foreign key — and an edge between two tables — out of a sentence. Masking is done
// for the *scan* only: statements are still quoted from the original text, so what
// the drawer shows is what source says, comments included.
//
// Quoted text is skipped, because `DEFAULT '--'` is a value and not a comment. Block
// comments nest, as they do in Postgres. This covers the DDL path alone; a comment
// inside a query is read by the statement scanner, which has its own gate.
func maskSQLComments(text string) string {
	out := []byte(text)
	blank := func(from, to int) {
		for i := from; i < to && i < len(out); i++ {
			if out[i] != '\n' {
				out[i] = ' '
			}
		}
	}
	for i := 0; i < len(text); i++ {
		switch text[i] {
		case '\'', '"':
			q := text[i]
			for i++; i < len(text) && text[i] != q; i++ {
			}
		case '-':
			if i+1 >= len(text) || text[i+1] != '-' {
				continue
			}
			end := len(text)
			if j := strings.IndexByte(text[i:], '\n'); j >= 0 {
				end = i + j
			}
			blank(i, end)
			i = end
		case '/':
			if i+1 >= len(text) || text[i+1] != '*' {
				continue
			}
			depth, j := 1, i+2
			for j+1 < len(text) && depth > 0 {
				switch {
				case text[j] == '/' && text[j+1] == '*':
					depth++
					j += 2
				case text[j] == '*' && text[j+1] == '/':
					depth--
					j += 2
				default:
					j++
				}
			}
			if depth > 0 {
				j = len(text)
			}
			blank(i, j)
			i = j - 1
		}
	}
	return string(out)
}

// maskSQLStrings blanks the contents of every single-quoted string, keeping the text
// the same length — and every newline where it was — so an index into the result still
// cites the same line.
//
// It is the same argument as maskSQLComments and the other half of it: a value is not
// a declaration, so `DEFAULT 'see REFERENCES models(id)'` must not mint a foreign key.
// Comments are masked for the whole DDL scan, but string *contents* are not, because a
// column's `DEFAULT` is part of what the drawer shows — so this one is applied by the
// scans that read keywords, and only by them.
//
// Double quotes are left alone: in SQL they quote an identifier, and `REFERENCES
// "models"` is a real reference to a real table. A doubled quote — SQL's escape for a
// quote inside a literal — closes the string and reopens it, which blanks the same
// bytes either way; an unterminated quote takes the
// rest of the text, which is the safe direction — a keyword inside an unterminated
// literal is not a declaration either. Dollar-quoted `$$ ... $$` bodies are *not*
// masked, because a `DO $$ ... ALTER TABLE ... $$` block really does declare what it
// contains.
func maskSQLStrings(text string) string {
	out := []byte(text)
	for i := 0; i < len(text); i++ {
		if text[i] != '\'' {
			continue
		}
		j := i + 1
		for ; j < len(text) && text[j] != '\''; j++ {
			if out[j] != '\n' {
				out[j] = ' '
			}
		}
		i = j
	}
	return string(out)
}

// statementAt returns the single SQL statement beginning at idx: everything up to
// the first semicolon at paren depth zero, or the end of the literal.
func statementAt(text string, idx int) string {
	start, end := statementSpan(text, idx)
	return dedent(strings.TrimSpace(text[start:end]))
}

// statementSpan is statementAt's extent, so a caller that scanned masked text can
// quote the same statement out of the original.
func statementSpan(text string, idx int) (int, int) {
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
				return idx, i + 1
			}
		}
	}
	return idx, len(text)
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

// parseColumns splits a CREATE TABLE body into columns, table-level constraints
// and the foreign keys either of them declares. Splitting is depth-aware, so
// `NUMERIC(10, 2)` and a multi-column `PRIMARY KEY (a, b)` stay in one piece.
//
// A foreign key is reported *as well as*, not instead of, whatever declared it: a
// table-level `FOREIGN KEY` is still a constraint of that table and an inline
// `REFERENCES` is still part of its column's definition. The key is the same fact
// read for a different question — which other table this one points at.
func parseColumns(body string, site func(int) string) ([]ir.Column, []ir.Constraint, []ir.ForeignKey) {
	var cols []ir.Column
	var cons []ir.Constraint
	var fks []ir.ForeignKey
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
			fks = append(fks, foreignKeys(text, nil, site(part.idx))...)
			continue
		}
		fields := tokenize(text)
		if len(fields) == 0 {
			continue
		}
		col := ir.Column{Name: cleanIdent(strings.ToLower(fields[0])), Site: site(part.idx)}
		col.Type, col.Extra = splitType(strings.Join(fields[1:], " "))
		cols = append(cols, col)
		fks = append(fks, foreignKeys(text, []string{col.Name}, site(part.idx))...)
	}
	return cols, cons, fks
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
