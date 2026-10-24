-- =====================================================================
-- dq_daily_mart.sql  -  logic + anomaly checks on daily estimates
-- Variables: run_date, run_id
-- =====================================================================
DELETE FROM audit.dq_results
WHERE run_id = :'run_id' AND scope = 'daily_mart' AND period = :'run_date'::date;

INSERT INTO audit.dq_results (run_id, scope, period, check_name, severity, observed, threshold, passed, details)
WITH m AS (
    SELECT * FROM mart.daily_brand_daypart_demo WHERE broadcast_date = :'run_date'::date
),
expected AS (
    SELECT (SELECT count(*) FROM ref.brand_platforms)
         * (SELECT count(*) FROM ref.dayparts)
         * (SELECT count(*) FROM ref.universe_estimates) AS n
),
-- Total Day reach can never be lower than the reach of any single daypart
daypart_logic AS (
    SELECT count(*) AS bad
    FROM (
        SELECT platform, brand_id, age_group, gender, region,
               MAX(reach_persons) FILTER (WHERE daypart = 'Total Day')  AS total_day,
               MAX(reach_persons) FILTER (WHERE daypart <> 'Total Day') AS best_daypart
        FROM m GROUP BY 1, 2, 3, 4, 5
    ) x
    WHERE total_day + 0.5 < best_daypart
),
-- Dayparts split the day exactly, so their minutes must add up to Total Day
minutes_logic AS (
    SELECT MAX(ABS(total_day - parts)) AS max_gap
    FROM (
        SELECT platform, brand_id, age_group, gender, region,
               SUM(weighted_minutes) FILTER (WHERE daypart = 'Total Day')  AS total_day,
               SUM(weighted_minutes) FILTER (WHERE daypart <> 'Total Day') AS parts
        FROM m GROUP BY 1, 2, 3, 4, 5
    ) x
),
-- Anomaly: Total Day reach by brand/platform/region vs same weekday last week
region_now AS (
    SELECT broadcast_date, platform, brand_name, region,
           SUM(reach_persons) AS reach, SUM(sample_viewers) AS n
    FROM mart.daily_brand_daypart_demo
    WHERE daypart = 'Total Day'
      AND broadcast_date IN (:'run_date'::date, :'run_date'::date - 7)
    GROUP BY 1, 2, 3, 4
),
wow AS (
    SELECT c.platform, c.brand_name, c.region,
           100.0 * (c.reach - p.reach) / NULLIF(p.reach, 0) AS pct_change
    FROM region_now c
    JOIN region_now p
      ON p.platform = c.platform AND p.brand_name = c.brand_name AND p.region = c.region
     AND p.broadcast_date = c.broadcast_date - 7
    WHERE c.broadcast_date = :'run_date'::date AND p.n >= 100   -- ignore small samples
),
anomalies AS (
    SELECT count(*) AS n,
           string_agg(format('%s %s %s %s%%', platform, brand_name, region,
                             to_char(pct_change, 'SG990')), '; '
                      ORDER BY abs(pct_change) DESC) AS list
    FROM wow WHERE abs(pct_change) > 40
),
checks AS (
    SELECT 'grid_rows_complete' AS check_name, 'ERROR' AS severity,
           (SELECT count(*) FROM m)::numeric AS observed, n::numeric AS threshold,
           (SELECT count(*) FROM m) = n AS passed,
           'One row per platform/brand/daypart/demo cell' AS details
    FROM expected
    UNION ALL
    SELECT 'reach_pct_out_of_range', 'ERROR', count(*), 0, count(*) = 0,
           'reach_pct must be between 0 and 100'
    FROM m WHERE reach_pct < 0 OR reach_pct > 100
    UNION ALL
    SELECT 'rating_above_reach_market', 'ERROR', count(*), 0, count(*) = 0,
           'Market rating cannot exceed market reach % (AMA <= reach)'
    FROM mart.v_daily_brand_daypart
    WHERE broadcast_date = :'run_date'::date AND rating_pct > reach_pct + 0.05
    UNION ALL
    SELECT 'total_day_below_daypart', 'ERROR', bad, 0, bad = 0,
           'Total Day reach lower than a single daypart' FROM daypart_logic
    UNION ALL
    SELECT 'daypart_minutes_mismatch', 'ERROR', ROUND(max_gap, 2), 1, max_gap <= 1,
           'Daypart minutes must add up to Total Day minutes' FROM minutes_logic
    UNION ALL
    SELECT 'week_on_week_anomalies', 'WARN', n, 0, n = 0,
           COALESCE('Reach moved >40% vs same day last week: ' || left(list, 900),
                    'No large week-on-week moves') FROM anomalies
)
SELECT :'run_id', 'daily_mart', :'run_date'::date, check_name, severity, observed, threshold,
       COALESCE(passed, false), details
FROM checks;
