-- Panel health per region and day: is the panel behind the numbers OK?
-- Vars: start_date, end_date
-- Run : bin/run_query.sh sql/analysis/01_intab_by_region.sql exports/analysis/intab.csv start_date=2026-09-14 end_date=2026-09-20
SELECT broadcast_date,
       region,
       SUM(panel_size)                                          AS panelists,
       SUM(intab)                                               AS intab,
       ROUND(100.0 * SUM(intab) / SUM(panel_size), 1)           AS intab_pct,
       ROUND(SUM(sum_weight) / NULLIF(SUM(intab), 0))           AS avg_weight,
       ROUND(MAX(max_weight))                                   AS max_weight
FROM mart.daily_intab_summary
WHERE broadcast_date BETWEEN :'start_date'::date AND :'end_date'::date
GROUP BY broadcast_date, region
ORDER BY region, broadcast_date;
