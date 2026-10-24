-- =====================================================================
-- dq_weights.sql  -  checks on panel weights (daily or weekly)
-- Variables: period, period_type (daily|weekly), run_id
-- =====================================================================
DELETE FROM audit.dq_results
WHERE run_id = :'run_id' AND scope = 'weights_' || :'period_type' AND period = :'period'::date;

CREATE TEMP TABLE t_w AS
SELECT panelist_id, weight FROM stg.daily_weights
WHERE :'period_type' = 'daily' AND broadcast_date = :'period'::date
UNION ALL
SELECT panelist_id, weight FROM stg.weekly_weights
WHERE :'period_type' = 'weekly' AND week_start = :'period'::date;

INSERT INTO audit.dq_results (run_id, scope, period, check_name, severity, observed, threshold, passed, details)
WITH wp AS (
    SELECT w.weight, p.age_group, p.gender, p.region
    FROM t_w w JOIN ref.panelists p USING (panelist_id)
),
universe_total AS (SELECT SUM(universe) AS u FROM ref.universe_estimates),
marginals AS (     -- weighted panel vs universe for each age / gender / region value
    SELECT 'age_group' AS dim, age_group AS val, SUM(weight) AS w FROM wp GROUP BY 2
    UNION ALL SELECT 'gender', gender, SUM(weight) FROM wp GROUP BY 2
    UNION ALL SELECT 'region', region, SUM(weight) FROM wp GROUP BY 2
),
targets AS (
    SELECT 'age_group' AS dim, age_group AS val, SUM(universe) AS u FROM ref.universe_estimates GROUP BY 2
    UNION ALL SELECT 'gender', gender, SUM(universe) FROM ref.universe_estimates GROUP BY 2
    UNION ALL SELECT 'region', region, SUM(universe) FROM ref.universe_estimates GROUP BY 2
),
marginal_gap AS (
    SELECT MAX(ABS(100.0 * (COALESCE(m.w, 0) - t.u) / t.u)) AS max_gap_pct
    FROM targets t LEFT JOIN marginals m USING (dim, val)
),
region_ess AS (    -- effective sample size per region (Kish)
    SELECT region, SUM(weight) ^ 2 / SUM(weight ^ 2) AS ess FROM wp GROUP BY 1
),
diag AS (
    SELECT * FROM audit.weighting_diagnostics
    WHERE period_type = :'period_type' AND period_start = :'period'::date
),
checks AS (
    SELECT 'weights_present' AS check_name, 'ERROR' AS severity,
           (SELECT count(*) FROM t_w)::numeric AS observed, 1::numeric AS threshold,
           (SELECT count(*) FROM t_w) > 0 AS passed, 'Weights exist for the period' AS details
    UNION ALL
    SELECT 'raking_converged', 'ERROR', converged::int, 1, converged,
           'Raking reached the universe targets' FROM diag
    UNION ALL
    SELECT 'sum_weights_vs_universe_pct', 'ERROR',
           ROUND(ABS(100.0 * ((SELECT SUM(weight) FROM t_w) - u) / u), 4), 0.5,
           ABS(100.0 * ((SELECT SUM(weight) FROM t_w) - u) / u) <= 0.5,
           'Weights must add up to the population' FROM universe_total
    UNION ALL
    SELECT 'max_marginal_gap_pct', 'ERROR', ROUND(max_gap_pct, 4), 1, max_gap_pct <= 1,
           'Every age/gender/region total within 1% of universe' FROM marginal_gap
    UNION ALL
    SELECT 'max_to_mean_weight_ratio', 'WARN', ROUND(max_weight / mean_weight, 2), 6,
           max_weight / mean_weight <= 6, 'Very large weights make estimates unstable' FROM diag
    UNION ALL
    SELECT 'design_effect', 'WARN', design_effect, 2, design_effect <= 2,
           'Precision lost to unequal weights (1 = none)' FROM diag
    UNION ALL
    SELECT 'ess_' || lower(region), 'WARN', ROUND(ess::numeric, 1), 100, ess >= 100,
           'Effective sample size in ' || region || ' too small for reliable regional numbers'
    FROM region_ess
)
SELECT :'run_id', 'weights_' || :'period_type', :'period'::date, check_name, severity,
       observed, threshold, COALESCE(passed, false), details
FROM checks;

-- daily only: every in-tab panelist must have a weight
INSERT INTO audit.dq_results (run_id, scope, period, check_name, severity, observed, threshold, passed, details)
SELECT :'run_id', 'weights_daily', :'period'::date, 'intab_without_weight', 'ERROR',
       count(*), 0, count(*) = 0, 'In-tab panelists missing a weight'
FROM stg.daily_intab i
LEFT JOIN t_w w USING (panelist_id)
WHERE :'period_type' = 'daily' AND i.broadcast_date = :'period'::date
  AND i.is_intab AND w.panelist_id IS NULL
HAVING :'period_type' = 'daily';

DROP TABLE t_w;
