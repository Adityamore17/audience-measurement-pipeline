-- =====================================================================
-- dq_staging.sql  -  data-quality checks after staging one day
-- Variables: run_date, run_id
-- ERROR = stop the pipeline. WARN = continue but report.
-- =====================================================================
DELETE FROM audit.dq_results
WHERE run_id = :'run_id' AND scope = 'staging' AND period = :'run_date'::date;

INSERT INTO audit.dq_results (run_id, scope, period, check_name, severity, observed, threshold, passed, details)
WITH s AS (
    SELECT * FROM audit.stage_stats WHERE broadcast_date = :'run_date'::date
),
intab_region AS (
    SELECT p.region, 100.0 * AVG(i.is_intab::int) AS rate
    FROM stg.daily_intab i JOIN ref.panelists p USING (panelist_id)
    WHERE i.broadcast_date = :'run_date'::date
    GROUP BY 1
),
checks AS (
    SELECT 'stage_stats_present' AS check_name, 'ERROR' AS severity,
           (SELECT count(*) FROM s)::numeric AS observed, 1::numeric AS threshold,
           (SELECT count(*) FROM s) = 1 AS passed,
           'Staging produced statistics for this day' AS details
    UNION ALL
    SELECT 'sessions_present', 'ERROR', sessions, 1, sessions >= 1,
           'At least one clean viewing session' FROM s
    UNION ALL
    SELECT 'invalid_row_rate_pct', 'ERROR',
           ROUND(100.0 * rejected_rows / NULLIF(raw_rows, 0), 3), 3,
           100.0 * rejected_rows / NULLIF(raw_rows, 0) <= 3,
           'Rows rejected as invalid (excluding duplicates)' FROM s
    UNION ALL
    SELECT 'duplicate_rate_pct', 'WARN',
           ROUND(100.0 * duplicate_rows / NULLIF(raw_rows, 0), 3), 3,
           100.0 * duplicate_rows / NULLIF(raw_rows, 0) <= 3,
           'High duplicate rate usually means a file was delivered twice' FROM s
    UNION ALL
    SELECT 'capped_session_rate_pct', 'WARN',
           ROUND(100.0 * capped_sessions / NULLIF(sessions, 0), 3), 2,
           100.0 * capped_sessions / NULLIF(sessions, 0) <= 2,
           'Sessions hitting the max-length rule (TV left on)' FROM s
    UNION ALL
    SELECT 'overall_intab_rate_pct', 'ERROR',
           ROUND(100.0 * AVG(is_intab::int), 2), 70, 100.0 * AVG(is_intab::int) >= 70,
           'Share of panel usable today'
    FROM stg.daily_intab WHERE broadcast_date = :'run_date'::date
    UNION ALL
    SELECT 'intab_rate_pct_' || lower(region), 'WARN', ROUND(rate, 2), 75, rate >= 75,
           'Region in-tab below normal - check meter data delivery for ' || region
    FROM intab_region
    UNION ALL
    -- Below 50% the few remaining panelists get huge weights and the
    -- region's numbers become unreliable -> stop before publishing.
    SELECT 'intab_critical_' || lower(region), 'ERROR', ROUND(rate, 2), 50, rate >= 50,
           'Region in-tab collapsed - likely meter data outage in ' || region
           || '. See SOP: check for late delivery, restate, or waive with sign-off'
    FROM intab_region
)
SELECT :'run_id', 'staging', :'run_date'::date, check_name, severity, observed, threshold,
       COALESCE(passed, false), details
FROM checks;
