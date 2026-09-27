package store

// Group by location and provider before rolling up the public location bucket.
// COUNT(DISTINCT provider_id) in the former single-level aggregate forced a
// sorted aggregate over every usage row: the production 24-hour window spilled
// to disk and exceeded the refresh deadline. Both levels here can use hash
// aggregation, reducing the intermediate rows before the final count sort.
//
// Coordinate sums carry their non-null sample counts so providers with unequal
// request counts do not receive equal weight. COUNT(provider_id) ignores the
// null-provider group, matching COUNT(DISTINCT provider_id); an empty ID still
// counts as one provider. The query and its timeout remain read-only.
const usageLocationBucketsSQL = `SELECT city, region, region_code, country, country_code,
       COALESCE(SUM(latitude_sum) / NULLIF(SUM(latitude_count), 0), 0),
       COALESCE(SUM(longitude_sum) / NULLIF(SUM(longitude_count), 0), 0),
       SUM(requests)::bigint,
       COALESCE(SUM(prompt_tokens), 0),
       COALESCE(SUM(completion_tokens), 0),
       COUNT(provider_id)
FROM (
    SELECT COALESCE(request_location->>'city', '') AS city,
           COALESCE(request_location->>'region', '') AS region,
           COALESCE(request_location->>'region_code', '') AS region_code,
           COALESCE(request_location->>'country', '') AS country,
           COALESCE(request_location->>'country_code', '') AS country_code,
           provider_id,
           SUM(NULLIF(request_location->>'latitude', '')::double precision) AS latitude_sum,
           COUNT(NULLIF(request_location->>'latitude', '')::double precision) AS latitude_count,
           SUM(NULLIF(request_location->>'longitude', '')::double precision) AS longitude_sum,
           COUNT(NULLIF(request_location->>'longitude', '')::double precision) AS longitude_count,
           COUNT(*) AS requests,
           SUM(prompt_tokens) AS prompt_tokens,
           SUM(completion_tokens) AS completion_tokens
    FROM usage
    WHERE request_location IS NOT NULL AND created_at >= $1
    GROUP BY city, region, region_code, country, country_code, provider_id
) AS location_usage_by_provider
GROUP BY city, region, region_code, country, country_code
ORDER BY SUM(requests) DESC`
