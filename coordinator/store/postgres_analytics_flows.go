package store

// Aggregate request origins per provider before joining provider locations.
// Joining and sorting every raw usage row exceeded the 10-second refresh
// deadline at production scale. Both grouping stages can hash; the provider
// join and final aggregation process only the reduced input. Coordinate sums
// retain their non-null sample counts,
// and provider coordinates are weighted by requests, matching the raw-row AVG.
//
// MATERIALIZED keeps the reduction before the provider lookup. The correlated
// OFFSET 0 keeps that lookup on the provider primary key even when PostgreSQL
// overestimates the number of groups and would otherwise scan all historical
// provider rows. Neither boundary changes which requests contribute to a flow.
// The cutoff, null-location handling, and top-50 contract are unchanged.
const usageFlowBucketsSQL = `WITH located_usage AS MATERIALIZED (
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
)
SELECT u.city AS c_city,
       u.region AS c_region,
       u.region_code AS c_region_code,
       u.country AS c_country,
       u.country_code AS c_country_code,
       COALESCE(SUM(u.latitude_sum) / NULLIF(SUM(u.latitude_count), 0), 0) AS c_lat,
       COALESCE(SUM(u.longitude_sum) / NULLIF(SUM(u.longitude_count), 0), 0) AS c_lng,
       COALESCE(p.location->>'city', '') AS p_city,
       COALESCE(p.location->>'region', '') AS p_region,
       COALESCE(p.location->>'region_code', '') AS p_region_code,
       COALESCE(p.location->>'country', '') AS p_country,
       COALESCE(p.location->>'country_code', '') AS p_country_code,
       COALESCE(
           SUM(NULLIF(p.location->>'latitude', '')::double precision * u.requests) /
           NULLIF(SUM(u.requests) FILTER (WHERE NULLIF(p.location->>'latitude', '') IS NOT NULL), 0),
           0) AS p_lat,
       COALESCE(
           SUM(NULLIF(p.location->>'longitude', '')::double precision * u.requests) /
           NULLIF(SUM(u.requests) FILTER (WHERE NULLIF(p.location->>'longitude', '') IS NOT NULL), 0),
           0) AS p_lng,
       SUM(u.requests)::bigint AS requests,
       COALESCE(SUM(u.prompt_tokens), 0) AS prompt_tokens,
       COALESCE(SUM(u.completion_tokens), 0) AS completion_tokens
FROM located_usage u
JOIN LATERAL (
    SELECT location FROM providers
    WHERE id = u.provider_id AND location IS NOT NULL
    OFFSET 0
) p ON true
GROUP BY u.city, u.region, u.region_code, u.country, u.country_code,
         p_city, p_region, p_region_code, p_country, p_country_code
ORDER BY requests DESC
LIMIT 50`
