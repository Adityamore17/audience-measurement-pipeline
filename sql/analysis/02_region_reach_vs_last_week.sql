-- Total-day reach for one region vs the same weekday last week, with the
-- unweighted sample behind each number. Big % moves on tiny samples = noise.
-- Vars: run_date, region
-- Run : bin/run_query.sh sql/analysis/02_region_reach_vs_last_week.sql exports/analysis/east_wow.csv run_date=2026-09-17 region=East
WITH r AS (
    SELECT broadcast_date, platform, brand_name,
           SUM(reach_persons)  AS reach,
           SUM(sample_viewers) AS sample
    FROM mart.daily_brand_daypart_demo
    WHERE daypart = 'Total Day'
      AND region = :'region'
      AND broadcast_date IN (:'run_date'::date, :'run_date'::date - 7)
    GROUP BY 1, 2, 3
)
SELECT cur.platform, cur.brand_name,
       ROUND(prev.reach)                                          AS reach_last_week,
       prev.sample                                                AS sample_last_week,
       ROUND(cur.reach)                                           AS reach_this_day,
       cur.sample                                                 AS sample_this_day,
       ROUND(100.0 * (cur.reach - prev.reach) / NULLIF(prev.reach, 0), 1) AS pct_change
FROM r cur
JOIN r prev
  ON prev.platform = cur.platform AND prev.brand_name = cur.brand_name
 AND prev.broadcast_date = cur.broadcast_date - 7
WHERE cur.broadcast_date = :'run_date'::date
ORDER BY ABS(cur.reach - prev.reach) DESC;
