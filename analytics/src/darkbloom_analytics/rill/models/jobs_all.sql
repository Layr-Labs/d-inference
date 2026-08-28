SELECT h.*
FROM jobs_history h
CROSS JOIN analytics_coverage c
WHERE h.event_at < c.hourly_covered_through

UNION ALL BY NAME

SELECT l.*
FROM jobs_live l
CROSS JOIN analytics_coverage c
WHERE l.event_at >= c.hourly_covered_through
