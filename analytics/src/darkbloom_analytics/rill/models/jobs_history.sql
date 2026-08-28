SELECT *
FROM read_parquet(
  '__ANALYTICS_ROOT__/parquet/jobs/**/*.parquet',
  hive_partitioning = true,
  union_by_name = true
)
