-- =====================================================================
-- 04_mart_daily.sql  -  daily audience estimates
-- Variables: run_date, qualifier_sec
--
-- Definitions (per platform x brand x daypart x demo cell)
--   universe       projected universe = sum of in-tab weights in the cell.
--                  Raking makes every age / gender / region total equal the
--                  official universe estimate exactly; single cells can
--                  differ a little, so we use the projection to keep
--                  reach % <= 100 everywhere.
--   reach_persons  projected people who viewed >= qualifier_sec in the daypart
--   AMA            average minute audience = weighted minutes / daypart minutes
--   rating_pct     AMA as % of the universe
--   sample_viewers unweighted panelists behind the estimate (reliability)
-- Only in-tab panelists (those with a weight) count.
-- =====================================================================
BEGIN;

-- In-tab summary (panel health) -----------------------------------------
DELETE FROM mart.daily_intab_summary WHERE broadcast_date = :'run_date'::date;

INSERT INTO mart.daily_intab_summary
SELECT :'run_date'::date, p.region, p.age_group, p.gender,
       count(*)                                     AS panel_size,
       count(*) FILTER (WHERE i.is_intab)           AS intab,
       ROUND(count(*) FILTER (WHERE i.is_intab)::numeric / count(*), 4),
       MAX(u.universe),
       COALESCE(SUM(w.weight), 0),
       MIN(w.weight), MAX(w.weight)
FROM ref.panelists p
JOIN stg.daily_intab i
  ON i.panelist_id = p.panelist_id AND i.broadcast_date = :'run_date'::date
JOIN ref.universe_estimates u USING (age_group, gender, region)
LEFT JOIN stg.daily_weights w
  ON w.panelist_id = p.panelist_id AND w.broadcast_date = :'run_date'::date
GROUP BY p.region, p.age_group, p.gender;

-- Brand x daypart x demo --------------------------------------------------
DELETE FROM mart.daily_brand_daypart_demo WHERE broadcast_date = :'run_date'::date;

WITH dp AS (
    SELECT daypart,
           (:'run_date'::date + time '06:00') + make_interval(mins => start_offset_min) AS dp_start,
           (:'run_date'::date + time '06:00') + make_interval(mins => end_offset_min)   AS dp_end,
           end_offset_min - start_offset_min                                            AS dp_minutes
    FROM ref.dayparts
),
viewing AS (       -- weighted, in-tab viewing only
    SELECT s.panelist_id, s.platform, s.brand_id, s.start_ts, s.end_ts,
           w.weight, p.age_group, p.gender, p.region
    FROM stg.viewing_sessions s
    JOIN stg.daily_weights w
      ON w.broadcast_date = s.broadcast_date AND w.panelist_id = s.panelist_id
    JOIN ref.panelists p ON p.panelist_id = s.panelist_id
    WHERE s.broadcast_date = :'run_date'::date
),
person_daypart AS (   -- seconds each person spent with each brand in each daypart
    SELECT v.panelist_id, v.platform, v.brand_id, dp.daypart, dp.dp_minutes,
           v.weight, v.age_group, v.gender, v.region,
           SUM(EXTRACT(EPOCH FROM LEAST(v.end_ts, dp.dp_end)
                                - GREATEST(v.start_ts, dp.dp_start))) AS secs
    FROM viewing v
    JOIN dp ON v.start_ts < dp.dp_end AND v.end_ts > dp.dp_start   -- overlap
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
),
agg AS (
    SELECT platform, brand_id, daypart, age_group, gender, region,
           SUM(weight)  FILTER (WHERE secs >= :'qualifier_sec'::int) AS reach_persons,
           COUNT(*)     FILTER (WHERE secs >= :'qualifier_sec'::int) AS sample_viewers,
           SUM(weight * secs) / 60.0                                  AS weighted_minutes,
           MAX(dp_minutes)                                            AS dp_minutes
    FROM person_daypart
    GROUP BY 1, 2, 3, 4, 5, 6
),
projected AS (     -- projected universe per demo cell = sum of in-tab weights
    SELECT p.age_group, p.gender, p.region, SUM(w.weight) AS universe
    FROM stg.daily_weights w
    JOIN ref.panelists p ON p.panelist_id = w.panelist_id
    WHERE w.broadcast_date = :'run_date'::date
    GROUP BY 1, 2, 3
),
grid AS (          -- every combination, so "no viewers" shows as 0, not missing
    SELECT bp.platform, bp.brand_id, b.brand_name, d.daypart,
           d.end_offset_min - d.start_offset_min AS dp_minutes,
           u.age_group, u.gender, u.region,
           COALESCE(pr.universe, 0) AS universe
    FROM ref.brand_platforms bp
    JOIN ref.brands b USING (brand_id)
    CROSS JOIN ref.dayparts d
    CROSS JOIN ref.universe_estimates u
    LEFT JOIN projected pr
           ON pr.age_group = u.age_group AND pr.gender = u.gender AND pr.region = u.region
)
INSERT INTO mart.daily_brand_daypart_demo
SELECT :'run_date'::date, g.platform, g.brand_id, g.brand_name, g.daypart,
       g.age_group, g.gender, g.region, ROUND(g.universe),
       COALESCE(a.reach_persons, 0),
       COALESCE(ROUND(100.0 * COALESCE(a.reach_persons, 0) / NULLIF(g.universe, 0), 4), 0),
       COALESCE(a.weighted_minutes, 0),
       COALESCE(a.weighted_minutes, 0) / g.dp_minutes,
       COALESCE(ROUND(100.0 * COALESCE(a.weighted_minutes, 0) / g.dp_minutes
                      / NULLIF(g.universe, 0), 4), 0),
       ROUND(COALESCE(a.weighted_minutes / NULLIF(a.reach_persons, 0), 0), 2),
       COALESCE(a.sample_viewers, 0)
FROM grid g
LEFT JOIN agg a USING (platform, brand_id, daypart, age_group, gender, region);

COMMIT;

SELECT platform, brand_name,
       ROUND(reach_persons / 1e6, 2) AS reach_m, reach_pct, rating_pct, share_pct
FROM mart.v_daily_brand_daypart
WHERE broadcast_date = :'run_date'::date AND daypart = 'Total Day' AND platform = 'TV'
ORDER BY reach_persons DESC;
