### Concurrent tensor-parallel requests draft together

- When several speculative requests on a two-Mac tensor-parallel pair draft in the same round, their assistant steps now run as one batch: one head call and one pair of sealed exchanges per draft step for every row, instead of one per row. Six concurrent requests need about a third of the reductions they needed before, and every request still produces exactly the tokens it produces alone.
