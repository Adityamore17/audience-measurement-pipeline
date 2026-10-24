-- =====================================================================
-- 05_mart_weekly.sql  -  weekly reach, frequency and cross-platform
-- Variables: week_start (a Monday), qualifier_sec
--
-- Uses weekly weights (panelists in-tab on enough days of the week) and
-- only counts viewing from days the panelist was in-tab.
--
-- Key idea: reach is NOT additive across platforms. Someone who watched
-- PlayMax on TV and on Mobile is one person, not two. The cross-platform
-- table counts each person once ("unduplicated reach").
-- =====================================================================
BEGIN;

DELETE FROM mart.weekly_brand_reach_demo    WHERE week_start = :'week_start'::date;
DELETE FROM mart.weekly_cross_platform_reach WHERE week_start = :'week_start'::date;

CREATE TEMP TABLE t_person_day ON COMMIT DROP AS   -- seconds per person/brand/platform/day
SELECT s.panelist_id, s.platform, s.brand_id, s.broadcast_date,
       SUM(s.duration_sec) AS secs
FROM stg.viewing_sessions s
JOIN stg.daily_intab i
  ON i.panelist_id = s.panelist_id AND i.broadcast_date = s.broadcast_date AND i.is_intab
WHERE s.broadcast_date BETWEEN :'week_start'::date AND :'week_start'::date + 6
GROUP BY 1, 2, 3, 4;

CREATE TEMP TABLE t_person_week ON COMMIT DROP AS  -- one row per person/brand/platform
SELECT pd.panelist_id, pd.platform, pd.brand_id,
       COUNT(*) FILTER (WHERE pd.secs >= :'qualifier_sec'::int) AS days_viewed,
       SUM(pd.secs)                                              AS secs,
       w.weight, p.age_group, p.gender, p.region
FROM t_person_day pd
JOIN stg.weekly_weights w
  ON w.panelist_id = pd.panelist_id AND w.week_start = :'week_start'::date
JOIN ref.panelists p ON p.panelist_id = pd.panelist_id
GROUP BY pd.panelist_id, pd.platform, pd.brand_id, w.weight, p.age_group, p.gender, p.region;

-- projected universe per demo cell (sum of weekly weights) - see 04_mart_daily.sql
CREATE TEMP TABLE t_cells ON COMMIT DROP AS
SELECT u.age_group, u.gender, u.region, ROUND(COALESCE(SUM(w.weight), 0)) AS universe
FROM ref.universe_estimates u
LEFT JOIN ref.panelists p
       ON p.age_group = u.age_group AND p.gender = u.gender AND p.region = u.region
LEFT JOIN stg.weekly_weights w
       ON w.panelist_id = p.panelist_id AND w.week_start = :'week_start'::date
GROUP BY 1, 2, 3;

-- Weekly reach + frequency per platform ------------------------------------
WITH agg AS (
    SELECT platform, brand_id, age_group, gender, region,
           SUM(weight)               FILTER (WHERE days_viewed > 0) AS reach_persons,
           SUM(weight * days_viewed) FILTER (WHERE days_viewed > 0) AS weighted_days,
           COUNT(*)                  FILTER (WHERE days_viewed > 0) AS sample_viewers,
           SUM(weight * secs) / 60.0                                AS weighted_minutes
    FROM t_person_week
    GROUP BY 1, 2, 3, 4, 5
),
grid AS (
    SELECT bp.platform, bp.brand_id, b.brand_name, c.age_group, c.gender, c.region, c.universe
    FROM ref.brand_platforms bp
    JOIN ref.brands b USING (brand_id)
    CROSS JOIN t_cells c
)
INSERT INTO mart.weekly_brand_reach_demo
SELECT :'week_start'::date, g.platform, g.brand_id, g.brand_name,
       g.age_group, g.gender, g.region, g.universe,
       COALESCE(a.reach_persons, 0),
       COALESCE(ROUND(100.0 * COALESCE(a.reach_persons, 0) / NULLIF(g.universe, 0), 4), 0),
       ROUND(COALESCE(a.weighted_days / NULLIF(a.reach_persons, 0), 0), 3),
       COALESCE(a.weighted_minutes, 0),
       ROUND(COALESCE(a.weighted_minutes / NULLIF(a.reach_persons, 0), 0), 2),
       COALESCE(a.sample_viewers, 0)
FROM grid g
LEFT JOIN agg a USING (platform, brand_id, age_group, gender, region);

-- Cross-platform (unduplicated) reach -------------------------------------
WITH person_brand AS (   -- which platforms each person used for each brand
    SELECT panelist_id, brand_id, weight, age_group, gender, region,
           BOOL_OR(platform = 'TV'      AND days_viewed > 0) AS on_tv,
           BOOL_OR(platform = 'Digital' AND days_viewed > 0) AS on_digital,
           BOOL_OR(platform = 'Mobile'  AND days_viewed > 0) AS on_mobile,
           BOOL_OR(platform = 'OTT'     AND days_viewed > 0) AS on_ott
    FROM t_person_week
    GROUP BY 1, 2, 3, 4, 5, 6
),
flags AS (
    SELECT *, (on_digital OR on_mobile OR on_ott) AS on_any_digital
    FROM person_brand
),
agg AS (
    SELECT brand_id, age_group, gender, region,
           SUM(weight) FILTER (WHERE on_tv)                                AS reach_tv,
           SUM(weight) FILTER (WHERE on_digital)                           AS reach_digital,
           SUM(weight) FILTER (WHERE on_mobile)                            AS reach_mobile,
           SUM(weight) FILTER (WHERE on_ott)                               AS reach_ott,
           SUM(weight) FILTER (WHERE on_tv OR on_any_digital)              AS reach_total,
           SUM(weight) FILTER (WHERE on_tv AND NOT on_any_digital)         AS reach_tv_only,
           SUM(weight) FILTER (WHERE on_any_digital AND NOT on_tv)         AS reach_digital_only,
           SUM(weight) FILTER (WHERE on_tv AND on_any_digital)             AS reach_both,
           COUNT(*)    FILTER (WHERE on_tv OR on_any_digital)              AS sample_viewers
    FROM flags
    GROUP BY 1, 2, 3, 4
),
grid AS (
    SELECT b.brand_id, b.brand_name, c.age_group, c.gender, c.region, c.universe
    FROM ref.brands b CROSS JOIN t_cells c
)
INSERT INTO mart.weekly_cross_platform_reach
SELECT :'week_start'::date, g.brand_id, g.brand_name, g.age_group, g.gender, g.region, g.universe,
       COALESCE(a.reach_tv, 0), COALESCE(a.reach_digital, 0), COALESCE(a.reach_mobile, 0),
       COALESCE(a.reach_ott, 0), COALESCE(a.reach_total, 0), COALESCE(a.reach_tv_only, 0),
       COALESCE(a.reach_digital_only, 0), COALESCE(a.reach_both, 0), COALESCE(a.sample_viewers, 0)
FROM grid g
LEFT JOIN agg a USING (brand_id, age_group, gender, region);

COMMIT;

SELECT brand_name, ROUND(reach_total_unduplicated / 1e6, 2) AS unduplicated_reach_m,
       reach_pct, duplication_pct
FROM mart.v_weekly_cross_platform
WHERE week_start = :'week_start'::date
ORDER BY reach_total_unduplicated DESC;
