# Golden metric names

`emitted_names.txt` and `mirror_names.txt` are a snapshot of every metric name
the coordinator emitted **before** the catalog existed: the DogStatsD names that
were spelled out at `s.ddIncr`/`ddCount`/`ddGauge`/`ddHistogram` call sites, and
the in-process registry names behind `GET /v1/admin/metrics`.

`catalog_test.go` asserts every declared name is in the matching snapshot. That
is what makes the migration non-destructive: a typo in a declaration would
otherwise mint a new series and silently retire the one a dashboard queries, and
nothing else in the build would notice.

The check is containment, not equality, while the migration is in flight — names
whose call sites have not moved yet are still emitted from those call sites. It
becomes an equality check when the last `ddX` shim is deleted.

## Regenerating

Run the extractor against a tree from **before** the migration, not the current
one: migrated call sites no longer contain the literal, so today's tree yields a
shrinking list.

```sh
git archive 513af2381 | tar -x -C /tmp/base    # last commit before the catalog
python3 coordinator/metrics/testdata/extract_names.py /tmp/base/api dd     > coordinator/metrics/testdata/emitted_names.txt
python3 coordinator/metrics/testdata/extract_names.py /tmp/base/api mirror > coordinator/metrics/testdata/mirror_names.txt
```

A name that legitimately did not exist before (a genuinely new metric) is added
by hand, with a one-line reason in the commit message.
