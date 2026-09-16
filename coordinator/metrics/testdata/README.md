# Golden metric names and tag keys

Three snapshots of what the coordinator emitted **before** the catalog existed,
taken from the call sites the declarations replace:

| File | Holds | Asserted by |
|---|---|---|
| `emitted_names.txt` | DogStatsD names spelled at `s.ddIncr`/`ddCount`/`ddGauge`/`ddHistogram` | `TestDeclaredNamesAlreadyExist` |
| `mirror_names.txt` | in-process registry names behind `GET /v1/admin/metrics` | `TestDeclaredNamesAlreadyExist` |
| `emitted_tag_keys.txt` | per name, each distinct **ordered** tag-key list observed | `TestDeclaredTagKeysMatchWhatWasEmitted` |

Together they are what makes the migration non-destructive. A typo in a
declaration would otherwise mint a new series and silently retire the one a
dashboard queries; a declaration that keeps the name but adds, drops or reorders
a tag key does the same thing to every widget that groups by it. Nothing else in
the build notices either.

A name may appear more than once in `emitted_tag_keys.txt`, because a site that
omitted a conditional dimension emitted a shorter list — `ws.disconnects` has
both `reason` and `reason,code`. The declaration covers that by taking an empty
value for the missing tag, so the test asks that each observed list be an ordered
*subsequence* of the declared keys rather than equal to them, and separately that
no declared key is one no call site ever emitted.

The name check is containment, not equality, while the migration is in flight —
names whose call sites have not moved yet are still emitted from those call
sites. It becomes an equality check when the last `ddX` shim is deleted.

## Regenerating

Run the extractor against a tree from **before** the migration, not the current
one: migrated call sites no longer contain the literal, so today's tree yields a
shrinking list.

```sh
git archive 513af2381 | tar -x -C /tmp/base    # last commit before the catalog
cd coordinator/metrics/testdata
python3 extract_names.py    /tmp/base/coordinator dd     > emitted_names.txt
python3 extract_names.py    /tmp/base/coordinator mirror > mirror_names.txt
python3 extract_tag_keys.py /tmp/base/coordinator        > emitted_tag_keys.txt
```

A name that legitimately did not exist before (a genuinely new metric) is added
by hand, with a one-line reason in the commit message.

`extract_tag_keys.py` only sees tag keys written as literals, at the call or in a
slice variable it can follow back. A site that carried its tags in a struct (the
MDM scheduler's gauge loop) leaves no evidence, so its name is absent from the
file and simply not asserted — partial coverage, deliberately, rather than a
guess. Extending the extractor is preferable to hand-editing the golden.
