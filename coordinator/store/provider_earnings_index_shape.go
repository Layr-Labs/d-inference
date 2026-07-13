package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

func concurrentIndexDefinitionMatches(
	ctx context.Context,
	queryer schemaQueryer,
	indexName string,
) (bool, error) {
	if indexName != "idx_provider_earnings_job" {
		return false, fmt.Errorf("no definition validator for %q", indexName)
	}

	var (
		valid               bool
		unique              bool
		ready               bool
		live                bool
		tableName           string
		accessMethod        string
		keyCount            int
		attributeCnt        int
		keyColumns          []string
		predicate           string
		opclass             string
		opclassNS           string
		usesColumnCollation bool
		sortOptions         int16
	)
	err := queryer.QueryRow(
		ctx,
		`SELECT
			i.indisvalid,
			i.indisunique,
			i.indisready,
			i.indislive,
			table_rel.relname,
			am.amname,
			i.indnkeyatts,
			i.indnatts,
			ARRAY(
				SELECT attr.attname::text
				FROM unnest(i.indkey) WITH ORDINALITY AS key(attnum, ord)
				JOIN pg_attribute attr
				  ON attr.attrelid = i.indrelid AND attr.attnum = key.attnum
				ORDER BY key.ord
			),
			COALESCE(pg_get_expr(i.indpred, i.indrelid, true), ''),
			opclass.opcname,
			opclass_namespace.nspname,
			i.indcollation[0] = key_attribute.attcollation,
			i.indoption[0]
		 FROM pg_class index_rel
		 JOIN pg_index i ON i.indexrelid = index_rel.oid
		 JOIN pg_class table_rel ON table_rel.oid = i.indrelid
		 JOIN pg_am am ON am.oid = index_rel.relam
		 JOIN pg_attribute key_attribute
		   ON key_attribute.attrelid = i.indrelid
		  AND key_attribute.attnum = i.indkey[0]
		 JOIN pg_opclass opclass ON opclass.oid = i.indclass[0]
		 JOIN pg_namespace opclass_namespace ON opclass_namespace.oid = opclass.opcnamespace
		 WHERE index_rel.oid = to_regclass($1)`,
		indexName,
	).Scan(
		&valid,
		&unique,
		&ready,
		&live,
		&tableName,
		&accessMethod,
		&keyCount,
		&attributeCnt,
		&keyColumns,
		&predicate,
		&opclass,
		&opclassNS,
		&usesColumnCollation,
		&sortOptions,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}

	return valid &&
		unique &&
		ready &&
		live &&
		tableName == "provider_earnings" &&
		accessMethod == "btree" &&
		keyCount == 1 &&
		attributeCnt == 1 &&
		len(keyColumns) == 1 &&
		keyColumns[0] == "job_id" &&
		opclass == "text_ops" &&
		opclassNS == "pg_catalog" &&
		usesColumnCollation &&
		sortOptions == 0 &&
		normalizeIndexPredicate(predicate) == "job_id <> ''::text", nil
}

func normalizeIndexPredicate(predicate string) string {
	predicate = strings.Join(strings.Fields(predicate), " ")
	for len(predicate) >= 2 && predicate[0] == '(' && predicate[len(predicate)-1] == ')' {
		predicate = strings.TrimSpace(predicate[1 : len(predicate)-1])
	}
	return predicate
}
