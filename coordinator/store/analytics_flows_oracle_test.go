package store

// Independent pre-optimization query: pin the existing flow semantics rather
// than constructing expected results with the new grouped query.
const originalFlowAggregateSQL = `SELECT
				COALESCE(u.request_location->>'city', '')         AS c_city,
				COALESCE(u.request_location->>'region', '')       AS c_region,
				COALESCE(u.request_location->>'region_code', '')  AS c_region_code,
				COALESCE(u.request_location->>'country', '')      AS c_country,
				COALESCE(u.request_location->>'country_code', '') AS c_country_code,
				COALESCE(AVG(NULLIF(u.request_location->>'latitude',  '')::double precision), 0) AS c_lat,
				COALESCE(AVG(NULLIF(u.request_location->>'longitude', '')::double precision), 0) AS c_lng,
				COALESCE(p.location->>'city', '')         AS p_city,
				COALESCE(p.location->>'region', '')       AS p_region,
				COALESCE(p.location->>'region_code', '')  AS p_region_code,
				COALESCE(p.location->>'country', '')      AS p_country,
				COALESCE(p.location->>'country_code', '') AS p_country_code,
				COALESCE(AVG(NULLIF(p.location->>'latitude',  '')::double precision), 0) AS p_lat,
				COALESCE(AVG(NULLIF(p.location->>'longitude', '')::double precision), 0) AS p_lng,
				COUNT(*)                              AS requests,
				COALESCE(SUM(u.prompt_tokens), 0)     AS prompt_tokens,
				COALESCE(SUM(u.completion_tokens), 0) AS completion_tokens
			 FROM usage u
			 JOIN providers p ON p.id = u.provider_id
			 WHERE u.request_location IS NOT NULL
			   AND p.location IS NOT NULL
			   AND u.created_at >= $1
			 GROUP BY c_city, c_region, c_region_code, c_country, c_country_code,
			          p_city, p_region, p_region_code, p_country, p_country_code
			 ORDER BY requests DESC
			 LIMIT 50`
