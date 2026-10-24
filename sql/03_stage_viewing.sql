-- =====================================================================
-- 03_stage_viewing.sql  -  clean, validate and de-duplicate viewing
-- Variables: run_date, max_session_min
--
-- Steps
--   1. standardise platform + brand spellings via alias tables
--   2. reject invalid rows (with a reason) into audit.rejected_events
--   3. remove duplicates (same person/platform/brand/start time)
--   4. clip to the broadcast day and cap "TV left on" sessions
--   5. merge overlapping fragments of one session (gaps-and-islands)
-- Idempotent: the day's previous output is deleted first.
-- =====================================================================
BEGIN;

DELETE FROM stg.viewing_sessions WHERE broadcast_date = :'run_date'::date;
DELETE FROM audit.rejected_events WHERE broadcast_date = :'run_date'::date;

-- 1 + 2: standardise and validate --------------------------------------
CREATE TEMP TABLE t_checked ON COMMIT DROP AS
WITH bounds AS (
    SELECT (:'run_date'::date + time '06:00')                     AS day_start,
           (:'run_date'::date + time '06:00') + interval '1 day'  AS day_end
),
typed AS (
    SELECT r.*,
           pa.platform                     AS platform_std,
           ba.brand_id,
           stg.try_timestamp(r.start_ts)   AS start_at,
           stg.try_timestamp(r.end_ts)     AS end_at,
           (p.panelist_id IS NOT NULL)     AS panelist_known
    FROM raw.viewing_events r
    LEFT JOIN ref.platform_aliases pa
           ON pa.alias_norm = lower(trim(r.platform))
    LEFT JOIN ref.brand_aliases ba
           ON ba.alias_norm = lower(regexp_replace(trim(r.brand), '\s+', ' ', 'g'))
    LEFT JOIN ref.panelists p
           ON p.panelist_id = r.panelist_id
    WHERE r.source_file LIKE 'viewing_events_' || :'run_date' || '%'
)
SELECT t.*, b.day_start, b.day_end,
       CASE
           WHEN t.platform_std IS NULL                     THEN 'UNKNOWN_PLATFORM'
           WHEN t.brand_id IS NULL                         THEN 'UNKNOWN_BRAND'
           WHEN NOT t.panelist_known                       THEN 'ORPHAN_PANELIST'
           WHEN t.start_at IS NULL OR t.end_at IS NULL     THEN 'BAD_TIMESTAMP'
           WHEN t.end_at <= t.start_at                     THEN 'NON_POSITIVE_DURATION'
           WHEN t.start_at <  b.day_start
             OR t.start_at >= b.day_end                    THEN 'OUTSIDE_BROADCAST_DAY'
       END AS reject_reason
FROM typed t CROSS JOIN bounds b;

INSERT INTO audit.rejected_events (broadcast_date, event_id, panelist_id, reason, raw_row)
SELECT :'run_date'::date, event_id, panelist_id, reject_reason,
       jsonb_build_object('event_id', event_id, 'panelist_id', panelist_id,
                          'platform', platform, 'brand', brand,
                          'start_ts', start_ts, 'end_ts', end_ts,
                          'source_file', source_file)
FROM t_checked
WHERE reject_reason IS NOT NULL;

-- 3: de-duplicate -------------------------------------------------------
-- Exact re-sends share event_id; near-duplicates share the natural key.
CREATE TEMP TABLE t_dedup ON COMMIT DROP AS
SELECT *,
       ROW_NUMBER() OVER (PARTITION BY panelist_id, platform_std, brand_id, start_at
                          ORDER BY end_at DESC, event_id)  AS rn
FROM t_checked
WHERE reject_reason IS NULL;

INSERT INTO audit.rejected_events (broadcast_date, event_id, panelist_id, reason, raw_row)
SELECT :'run_date'::date, event_id, panelist_id, 'DUPLICATE',
       jsonb_build_object('event_id', event_id, 'panelist_id', panelist_id,
                          'platform', platform, 'brand', brand,
                          'start_ts', start_ts, 'end_ts', end_ts,
                          'source_file', source_file)
FROM t_dedup
WHERE rn > 1;

-- 4: clip to broadcast day + cap long sessions --------------------------
CREATE TEMP TABLE t_clean ON COMMIT DROP AS
SELECT panelist_id, household_id, platform_std AS platform, brand_id, start_at,
       LEAST(end_at, day_end,
             start_at + make_interval(mins => :'max_session_min'::int))            AS end_at,
       (end_at > start_at + make_interval(mins => :'max_session_min'::int))       AS is_capped
FROM t_dedup
WHERE rn = 1;

-- 5: merge overlapping fragments (gaps-and-islands) ---------------------
-- A record starts a new "island" if it begins after every earlier record
-- for the same person/platform/brand has ended.
WITH ordered AS (
    SELECT *,
           MAX(end_at) OVER (PARTITION BY panelist_id, platform, brand_id
                             ORDER BY start_at, end_at
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
    FROM t_clean
),
flagged AS (
    SELECT *,
           CASE WHEN prev_max_end IS NULL OR start_at > prev_max_end THEN 1 ELSE 0 END AS new_island
    FROM ordered
),
islands AS (
    SELECT *,
           SUM(new_island) OVER (PARTITION BY panelist_id, platform, brand_id
                                 ORDER BY start_at, end_at
                                 ROWS UNBOUNDED PRECEDING) AS island_id
    FROM flagged
)
INSERT INTO stg.viewing_sessions
       (broadcast_date, panelist_id, household_id, platform, brand_id,
        start_ts, end_ts, duration_sec, is_capped, n_source_records)
SELECT :'run_date'::date, panelist_id, MAX(household_id), platform, brand_id,
       MIN(start_at), MAX(end_at),
       EXTRACT(EPOCH FROM MAX(end_at) - MIN(start_at))::int,
       BOOL_OR(is_capped),
       COUNT(*)
FROM islands
GROUP BY panelist_id, platform, brand_id, island_id;

-- run statistics (used by the data-quality checks) -----------------------
INSERT INTO audit.stage_stats (broadcast_date, raw_rows, rejected_rows, duplicate_rows,
                               valid_records, sessions, merged_fragments, capped_sessions)
SELECT :'run_date'::date,
       (SELECT count(*) FROM t_checked),
       (SELECT count(*) FROM t_checked WHERE reject_reason IS NOT NULL),
       (SELECT count(*) FROM t_dedup WHERE rn > 1),
       (SELECT count(*) FROM t_clean),
       count(*),
       COALESCE(SUM(n_source_records - 1), 0),
       count(*) FILTER (WHERE is_capped)
FROM stg.viewing_sessions
WHERE broadcast_date = :'run_date'::date
ON CONFLICT (broadcast_date) DO UPDATE SET
       raw_rows = EXCLUDED.raw_rows, rejected_rows = EXCLUDED.rejected_rows,
       duplicate_rows = EXCLUDED.duplicate_rows, valid_records = EXCLUDED.valid_records,
       sessions = EXCLUDED.sessions, merged_fragments = EXCLUDED.merged_fragments,
       capped_sessions = EXCLUDED.capped_sessions, computed_at = now();

COMMIT;

SELECT reason, count(*) AS rows
FROM audit.rejected_events
WHERE broadcast_date = :'run_date'::date
GROUP BY 1 ORDER BY 2 DESC;
