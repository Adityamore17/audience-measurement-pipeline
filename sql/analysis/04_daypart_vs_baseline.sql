-- One brand on one day vs its baseline (same weekday, previous 3 weeks), by
-- platform and daypart. Shows WHERE a spike or drop happened.
-- Vars: run_date, brand
-- Run : bin/run_query.sh sql/analysis/04_daypart_vs_baseline.sql exports/analysis/playmax_0920.csv run_date=2026-09-20 brand=PlayMax
WITH d AS (
    SELECT broadcast_date, platform, daypart, rating_pct, reach_pct
    FROM mart.v_daily_brand_daypart
    WHERE brand_name = :'brand'
      AND broadcast_date IN (:'run_date'::date, :'run_date'::date - 7,
                             :'run_date'::date - 14, :'run_date'::date - 21)
),
base AS (
    SELECT platform, daypart,
           AVG(rating_pct) AS base_rating, AVG(reach_pct) AS base_reach, COUNT(*) AS weeks
    FROM d WHERE broadcast_date < :'run_date'::date
    GROUP BY 1, 2
)
SELECT d.platform, d.daypart,
       ROUND(b.base_rating, 3)                                   AS baseline_rating_pct,
       d.rating_pct                                              AS rating_pct,
       ROUND(d.rating_pct / NULLIF(b.base_rating, 0), 2)         AS rating_index,
       ROUND(b.base_reach, 2)                                    AS baseline_reach_pct,
       d.reach_pct                                               AS reach_pct,
       b.weeks                                                   AS baseline_weeks
FROM d
JOIN base b USING (platform, daypart)
JOIN ref.dayparts dp USING (daypart)
WHERE d.broadcast_date = :'run_date'::date
ORDER BY d.platform, dp.sort_order;
