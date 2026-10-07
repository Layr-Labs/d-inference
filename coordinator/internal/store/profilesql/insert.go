package profilesql

import (
	"strconv"
	"strings"
	"sync"
)

// profileInsertShapes are the only multi-row INSERT arities ever sent for
// request_profiles, so the per-connection prepared-statement cache holds at
// most three distinct statements. Input is chunked to the largest shape and
// each chunk is padded (by repeating its last row) up to the next shape;
// padded duplicates are absorbed by ON CONFLICT DO NOTHING inside the same
// statement. Skipped rows still consume BIGSERIAL values, so ids can have
// gaps — harmless: the retention sweep walks id ranges bounded by the time
// index and never assumes density.
var InsertShapes = [...]int{1, 8, 64}

var (
	insertSQLOnce sync.Once
	insertSQL     map[int]string
)

// requestProfileInsertSQL returns the cached multi-row INSERT for shape rows.
func InsertSQL(shape int) string {
	insertSQLOnce.Do(func() {
		insertSQL = make(map[int]string, len(InsertShapes))
		for _, n := range InsertShapes {
			insertSQL[n] = buildInsertSQL(n)
		}
	})
	return insertSQL[shape]
}

// buildRequestProfileInsertSQL renders
//
//	INSERT INTO request_profiles (<cols>) VALUES ($1,...),($n+1,...) ON CONFLICT (request_id, attempt) DO NOTHING
//
// with numbered placeholders for rows rows.
func buildInsertSQL(rows int) string {
	cols := len(RequestColumns)
	var b strings.Builder
	b.Grow(96 + cols*28 + rows*cols*6)
	b.WriteString("INSERT INTO request_profiles (")
	b.WriteString(strings.Join(RequestColumns, ", "))
	b.WriteString(") VALUES ")
	p := 1
	for r := 0; r < rows; r++ {
		if r > 0 {
			b.WriteString(", ")
		}
		b.WriteByte('(')
		for c := 0; c < cols; c++ {
			if c > 0 {
				b.WriteByte(',')
			}
			b.WriteByte('$')
			b.WriteString(strconv.Itoa(p))
			p++
		}
		b.WriteByte(')')
	}
	b.WriteString(" ON CONFLICT (request_id, attempt) DO NOTHING")
	return b.String()
}

// profileInsertShape returns the smallest shape that fits n rows
// (1 <= n <= profileInsertShapes[last]).
func InsertShape(n int) int {
	for _, s := range InsertShapes {
		if n <= s {
			return s
		}
	}
	return InsertShapes[len(InsertShapes)-1]
}
