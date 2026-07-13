package store

import (
	"fmt"
	"strings"
)

// splitSQLStatements splits a migration without treating semicolons inside
// quoted strings, dollar-quoted PL/pgSQL blocks, or comments as boundaries.
// Nontransactional migrations need this because concurrent index statements
// must each reach PostgreSQL as a standalone command.
func splitSQLStatements(sql string) ([]string, error) {
	var (
		statements   []string
		start        int
		singleQuoted bool
		doubleQuoted bool
		lineComment  bool
		blockDepth   int
		dollarTag    string
	)

	for i := 0; i < len(sql); i++ {
		if lineComment {
			if sql[i] == '\n' {
				lineComment = false
			}
			continue
		}
		if blockDepth > 0 {
			switch {
			case i+1 < len(sql) && sql[i:i+2] == "/*":
				blockDepth++
				i++
			case i+1 < len(sql) && sql[i:i+2] == "*/":
				blockDepth--
				i++
			}
			continue
		}
		if dollarTag != "" {
			if strings.HasPrefix(sql[i:], dollarTag) {
				i += len(dollarTag) - 1
				dollarTag = ""
			}
			continue
		}
		if singleQuoted {
			if sql[i] == '\'' {
				if i+1 < len(sql) && sql[i+1] == '\'' {
					i++
				} else {
					singleQuoted = false
				}
			}
			continue
		}
		if doubleQuoted {
			if sql[i] == '"' {
				if i+1 < len(sql) && sql[i+1] == '"' {
					i++
				} else {
					doubleQuoted = false
				}
			}
			continue
		}

		switch {
		case i+1 < len(sql) && sql[i:i+2] == "--":
			lineComment = true
			i++
		case i+1 < len(sql) && sql[i:i+2] == "/*":
			blockDepth = 1
			i++
		case sql[i] == '\'':
			singleQuoted = true
		case sql[i] == '"':
			doubleQuoted = true
		case sql[i] == '$':
			if tag, ok := scanDollarTag(sql[i:]); ok {
				dollarTag = tag
				i += len(tag) - 1
			}
		case sql[i] == ';':
			if statement := strings.TrimSpace(sql[start:i]); statement != "" {
				statements = append(statements, statement)
			}
			start = i + 1
		}
	}

	switch {
	case singleQuoted:
		return nil, fmt.Errorf("unterminated single-quoted string")
	case doubleQuoted:
		return nil, fmt.Errorf("unterminated double-quoted identifier")
	case dollarTag != "":
		return nil, fmt.Errorf("unterminated dollar-quoted block %s", dollarTag)
	case blockDepth != 0:
		return nil, fmt.Errorf("unterminated block comment")
	}
	if statement := strings.TrimSpace(sql[start:]); statement != "" {
		statements = append(statements, statement)
	}
	return statements, nil
}

func scanDollarTag(sql string) (string, bool) {
	if len(sql) < 2 || sql[0] != '$' {
		return "", false
	}
	for i := 1; i < len(sql); i++ {
		switch c := sql[i]; {
		case c == '$':
			return sql[:i+1], true
		case c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9':
			continue
		default:
			return "", false
		}
	}
	return "", false
}
