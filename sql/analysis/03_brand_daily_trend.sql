-- Daily trend: total-day reach % and prime-time rating per brand on one platform.
-- Vars: platform
-- Run : bin/run_query.sh sql/analysis/03_brand_daily_trend.sql exports/analysis/tv_trend.csv platform=TV
SELECT td.broadcast_date,
       to_char(td.broadcast_date, 'Dy')  AS weekday,
       td.brand_name,
       td.reach_pct                      AS total_day_reach_pct,
       pt.rating_pct                     AS prime_time_rating_pct,
       pt.share_pct                      AS prime_time_share_pct
FROM mart.v_daily_brand_daypart td
JOIN mart.v_daily_brand_daypart pt
  ON pt.broadcast_date = td.broadcast_date AND pt.platform = td.platform
 AND pt.brand_id = td.brand_id AND pt.daypart = 'Prime Time'
WHERE td.daypart = 'Total Day' AND td.platform = :'platform'
ORDER BY td.broadcast_date, td.brand_name;
