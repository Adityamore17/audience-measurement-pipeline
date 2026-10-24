-- Where does each brand's audience come from? TV only / digital only / both,
-- by age group, for one week.
-- Vars: week_start
-- Run : bin/run_query.sh sql/analysis/06_cross_platform_by_age.sql exports/analysis/xplat_age.csv week_start=2026-09-21
SELECT brand_name, age_group,
       ROUND(100.0 * SUM(reach_total_unduplicated) / SUM(universe), 1)               AS reach_pct,
       ROUND(100.0 * SUM(reach_tv_only)        / NULLIF(SUM(reach_total_unduplicated), 0), 1) AS tv_only_pct,
       ROUND(100.0 * SUM(reach_digital_only)   / NULLIF(SUM(reach_total_unduplicated), 0), 1) AS digital_only_pct,
       ROUND(100.0 * SUM(reach_tv_and_digital) / NULLIF(SUM(reach_total_unduplicated), 0), 1) AS both_pct
FROM mart.weekly_cross_platform_reach
WHERE week_start = :'week_start'::date
GROUP BY brand_name, age_group
ORDER BY brand_name, age_group;
