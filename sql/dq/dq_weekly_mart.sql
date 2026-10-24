-- =====================================================================
-- dq_weekly_mart.sql  -  logic checks on weekly reach / cross-platform
-- Variables: week_start, run_id
-- =====================================================================
DELETE FROM audit.dq_results
WHERE run_id = :'run_id' AND scope = 'weekly_mart' AND period = :'week_start'::date;

INSERT INTO audit.dq_results (run_id, scope, period, check_name, severity, observed, threshold, passed, details)
WITH x AS (
    SELECT * FROM mart.weekly_cross_platform_reach WHERE week_start = :'week_start'::date
),
r AS (
    SELECT * FROM mart.weekly_brand_reach_demo WHERE week_start = :'week_start'::date
),
checks AS (
    SELECT 'reach_rows_complete' AS check_name, 'ERROR' AS severity,
           (SELECT count(*) FROM r)::numeric AS observed,
           ((SELECT count(*) FROM ref.brand_platforms)
             * (SELECT count(*) FROM ref.universe_estimates))::numeric AS threshold,
           (SELECT count(*) FROM r) = (SELECT count(*) FROM ref.brand_platforms)
                                      * (SELECT count(*) FROM ref.universe_estimates) AS passed,
           'One row per platform/brand/demo cell' AS details
    UNION ALL
    SELECT 'unduplicated_below_single_platform', 'ERROR', count(*), 0, count(*) = 0,
           'Unduplicated reach must be >= each single platform reach'
    FROM x
    WHERE reach_total_unduplicated + 0.5 < GREATEST(reach_tv, reach_digital, reach_mobile, reach_ott)
    UNION ALL
    SELECT 'unduplicated_above_sum', 'ERROR', count(*), 0, count(*) = 0,
           'Unduplicated reach must be <= sum of platform reaches'
    FROM x
    WHERE reach_total_unduplicated > reach_tv + reach_digital + reach_mobile + reach_ott + 0.5
    UNION ALL
    SELECT 'venn_parts_add_up', 'ERROR', count(*), 0, count(*) = 0,
           'TV only + digital only + both must equal unduplicated reach'
    FROM x
    WHERE ABS(reach_tv_only + reach_digital_only + reach_tv_and_digital - reach_total_unduplicated) > 0.5
    UNION ALL
    SELECT 'frequency_out_of_range', 'ERROR', count(*), 0, count(*) = 0,
           'Average days viewed must be between 1 and 7 for anyone reached'
    FROM r
    WHERE reach_persons > 0 AND (avg_frequency_days < 1 OR avg_frequency_days > 7)
    UNION ALL
    SELECT 'weekly_reach_pct_out_of_range', 'ERROR', count(*), 0, count(*) = 0,
           'reach_pct must be between 0 and 100'
    FROM r WHERE reach_pct < 0 OR reach_pct > 100
)
SELECT :'run_id', 'weekly_mart', :'week_start'::date, check_name, severity, observed, threshold,
       COALESCE(passed, false), details
FROM checks;
