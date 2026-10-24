-- Weekly reach and average frequency (days viewed) per brand and platform.
-- Vars: none
-- Run : bin/run_query.sh sql/analysis/05_weekly_reach_frequency.sql exports/analysis/weekly_rf.csv
SELECT week_start, platform, brand_name,
       ROUND(SUM(reach_persons) / 1e6, 2)                               AS reach_m,
       ROUND(100.0 * SUM(reach_persons) / SUM(universe), 2)              AS reach_pct,
       ROUND(SUM(reach_persons * avg_frequency_days)
             / NULLIF(SUM(reach_persons), 0), 2)                         AS avg_days_viewed,
       ROUND(SUM(weighted_minutes) / NULLIF(SUM(reach_persons), 0), 1)  AS avg_min_per_viewer,
       SUM(sample_viewers)                                               AS sample
FROM mart.weekly_brand_reach_demo
GROUP BY week_start, platform, brand_name
ORDER BY week_start, platform, reach_m DESC;
