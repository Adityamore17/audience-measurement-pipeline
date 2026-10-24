-- =====================================================================
-- 00_schema.sql  -  create all schemas, tables, functions (idempotent)
--
-- Layers:
--   raw    files landed exactly as received (all text, nothing fixed)
--   ref    reference data: panel, universe estimates, brands, dayparts
--   stg    cleaned + validated data, panel weights
--   mart   reporting tables used by Power BI / Excel
--   audit  run log, rejected rows, data-quality results, weighting stats
-- =====================================================================

SET client_min_messages = warning;   -- hide 'already exists, skipping' notices

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS audit;

-- ---------------------------------------------------------------- raw
CREATE TABLE IF NOT EXISTS raw.viewing_events (
    event_id      text,
    panelist_id   text,
    household_id  text,
    platform      text,
    brand         text,
    start_ts      text,
    end_ts        text,
    source_file   text        NOT NULL,
    loaded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_raw_viewing_source ON raw.viewing_events (source_file);

CREATE TABLE IF NOT EXISTS raw.intab (
    household_id   text,
    broadcast_date text,
    meter_status   text,
    source_file    text        NOT NULL,
    loaded_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_raw_intab_source ON raw.intab (source_file);

-- ---------------------------------------------------------------- ref
CREATE TABLE IF NOT EXISTS ref.households (
    household_id   text PRIMARY KEY,
    region         text NOT NULL,
    household_size int  NOT NULL
);

CREATE TABLE IF NOT EXISTS ref.panelists (
    panelist_id  text PRIMARY KEY,
    household_id text NOT NULL REFERENCES ref.households,
    age_group    text NOT NULL,
    gender       text NOT NULL,
    region       text NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_panelists_hh ON ref.panelists (household_id);

-- Universe estimate = how many people in the population each demo cell represents
CREATE TABLE IF NOT EXISTS ref.universe_estimates (
    age_group text,
    gender    text,
    region    text,
    universe  bigint NOT NULL CHECK (universe > 0),
    PRIMARY KEY (age_group, gender, region)
);

CREATE TABLE IF NOT EXISTS ref.brands (
    brand_id   text PRIMARY KEY,
    brand_name text NOT NULL,
    genre      text NOT NULL
);

CREATE TABLE IF NOT EXISTS ref.brand_platforms (
    brand_id text REFERENCES ref.brands,
    platform text,
    PRIMARY KEY (brand_id, platform)
);

-- messy spellings seen in feeds -> clean ids (lower-cased, trimmed)
CREATE TABLE IF NOT EXISTS ref.brand_aliases (
    alias_norm text PRIMARY KEY,
    brand_id   text NOT NULL REFERENCES ref.brands
);

CREATE TABLE IF NOT EXISTS ref.platform_aliases (
    alias_norm text PRIMARY KEY,
    platform   text NOT NULL
);

-- dayparts as minute offsets from 06:00 (broadcast day = 06:00 -> 06:00)
CREATE TABLE IF NOT EXISTS ref.dayparts (
    daypart          text PRIMARY KEY,
    start_offset_min int  NOT NULL,
    end_offset_min   int  NOT NULL,
    sort_order       int  NOT NULL
);

-- ---------------------------------------------------------------- stg
CREATE TABLE IF NOT EXISTS stg.daily_intab (
    broadcast_date date,
    panelist_id    text,
    household_id   text    NOT NULL,
    meter_status   text    NOT NULL,     -- OK / NO_DATA / FAULTY / MISSING
    is_intab       boolean NOT NULL,     -- usable for measurement that day
    PRIMARY KEY (broadcast_date, panelist_id)
);

CREATE TABLE IF NOT EXISTS stg.viewing_sessions (
    session_id         bigserial PRIMARY KEY,
    broadcast_date     date      NOT NULL,
    panelist_id        text      NOT NULL,
    household_id       text,
    platform           text      NOT NULL,
    brand_id           text      NOT NULL,
    start_ts           timestamp NOT NULL,
    end_ts             timestamp NOT NULL,
    duration_sec       int       NOT NULL CHECK (duration_sec > 0),
    is_capped          boolean   NOT NULL,   -- hit the max-session rule
    n_source_records   int       NOT NULL    -- >1 means fragments were merged
);
CREATE INDEX IF NOT EXISTS ix_sessions_date ON stg.viewing_sessions (broadcast_date, panelist_id);

CREATE TABLE IF NOT EXISTS stg.daily_weights (
    broadcast_date date,
    panelist_id    text,
    weight         numeric(14,4) NOT NULL CHECK (weight > 0),
    PRIMARY KEY (broadcast_date, panelist_id)
);

CREATE TABLE IF NOT EXISTS stg.weekly_weights (
    week_start  date,
    panelist_id text,
    weight      numeric(14,4) NOT NULL CHECK (weight > 0),
    PRIMARY KEY (week_start, panelist_id)
);

-- ---------------------------------------------------------------- audit
CREATE TABLE IF NOT EXISTS audit.pipeline_runs (
    run_id      text,
    step        text,
    run_date    text,
    status      text,          -- STARTED / SUCCESS / FAILED
    message     text,
    logged_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit.rejected_events (
    broadcast_date date        NOT NULL,
    event_id       text,
    panelist_id    text,
    reason         text        NOT NULL,
    raw_row        jsonb       NOT NULL,
    rejected_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_rejected_date ON audit.rejected_events (broadcast_date);

CREATE TABLE IF NOT EXISTS audit.stage_stats (
    broadcast_date     date PRIMARY KEY,
    raw_rows           int,
    rejected_rows      int,     -- invalid rows (excludes duplicates)
    duplicate_rows     int,
    valid_records      int,
    sessions           int,
    merged_fragments   int,
    capped_sessions    int,
    computed_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit.weighting_diagnostics (
    period_type     text,      -- daily / weekly
    period_start    date,
    n_respondents   int,
    sum_weight      numeric,
    min_weight      numeric,
    max_weight      numeric,
    mean_weight     numeric,
    eff_sample_size numeric,   -- Kish: (sum w)^2 / sum(w^2)
    design_effect   numeric,   -- n / ESS
    iterations      int,
    n_trimmed       int,
    converged       boolean,
    computed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_type, period_start)
);

CREATE TABLE IF NOT EXISTS audit.dq_results (
    run_id        text,
    scope         text,         -- staging / weights / daily_mart / weekly_mart
    period        date,
    check_name    text,
    severity      text,         -- ERROR stops the pipeline, WARN is reported
    observed      numeric,
    threshold     numeric,
    passed        boolean,
    details       text,
    checked_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- mart
-- Grain: date x platform x brand x daypart x age x gender x region.
-- Additive across demo cells (a person is in exactly one cell).
-- NOT additive across dayparts or platforms (same person can be in several).
CREATE TABLE IF NOT EXISTS mart.daily_brand_daypart_demo (
    broadcast_date      date,
    platform            text,
    brand_id            text,
    brand_name          text,
    daypart             text,
    age_group           text,
    gender              text,
    region              text,
    universe            bigint,
    reach_persons       numeric(16,1),  -- projected persons who viewed >= qualifier
    reach_pct           numeric(8,4),
    weighted_minutes    numeric(18,1),
    ama                 numeric(16,1),  -- average minute audience
    rating_pct          numeric(8,4),   -- AMA as % of universe
    avg_min_per_viewer  numeric(10,2),
    sample_viewers      int,            -- unweighted panelists behind the number
    PRIMARY KEY (broadcast_date, platform, brand_id, daypart, age_group, gender, region)
);

CREATE TABLE IF NOT EXISTS mart.daily_intab_summary (
    broadcast_date  date,
    region          text,
    age_group       text,
    gender          text,
    panel_size      int,
    intab           int,
    intab_rate      numeric(6,4),
    universe        bigint,
    sum_weight      numeric(16,1),
    min_weight      numeric(14,2),
    max_weight      numeric(14,2),
    PRIMARY KEY (broadcast_date, region, age_group, gender)
);

CREATE TABLE IF NOT EXISTS mart.weekly_brand_reach_demo (
    week_start          date,
    platform            text,
    brand_id            text,
    brand_name          text,
    age_group           text,
    gender              text,
    region              text,
    universe            bigint,
    reach_persons       numeric(16,1),
    reach_pct           numeric(8,4),
    avg_frequency_days  numeric(6,3),   -- avg days viewed, among people reached
    weighted_minutes    numeric(18,1),
    avg_min_per_viewer  numeric(10,2),
    sample_viewers      int,
    PRIMARY KEY (week_start, platform, brand_id, age_group, gender, region)
);

CREATE TABLE IF NOT EXISTS mart.weekly_cross_platform_reach (
    week_start           date,
    brand_id             text,
    brand_name           text,
    age_group            text,
    gender               text,
    region               text,
    universe             bigint,
    reach_tv             numeric(16,1),
    reach_digital        numeric(16,1),
    reach_mobile         numeric(16,1),
    reach_ott            numeric(16,1),
    reach_total_unduplicated numeric(16,1),
    reach_tv_only        numeric(16,1),
    reach_digital_only   numeric(16,1),  -- any of Digital/Mobile/OTT, no TV
    reach_tv_and_digital numeric(16,1),
    sample_viewers       int,
    PRIMARY KEY (week_start, brand_id, age_group, gender, region)
);

-- ---------------------------------------------------------------- helpers
-- Returns NULL instead of raising an error when text is not a valid timestamp
CREATE OR REPLACE FUNCTION stg.try_timestamp(p text)
RETURNS timestamp LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p IS NULL OR p !~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$' THEN
        RETURN NULL;
    END IF;
    RETURN p::timestamp;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- ---------------------------------------------------------------- views
-- Market-level daily numbers (demo cells summed) + share within platform/daypart
CREATE OR REPLACE VIEW mart.v_daily_brand_daypart AS
WITH t AS (
    SELECT broadcast_date, platform, brand_id, brand_name, daypart,
           SUM(universe)          AS universe,
           SUM(reach_persons)     AS reach_persons,
           SUM(weighted_minutes)  AS weighted_minutes,
           SUM(ama)               AS ama,
           SUM(sample_viewers)    AS sample_viewers
    FROM mart.daily_brand_daypart_demo
    GROUP BY 1, 2, 3, 4, 5
)
SELECT t.*,
       ROUND(100.0 * reach_persons / universe, 3)                        AS reach_pct,
       ROUND(100.0 * ama / universe, 3)                                  AS rating_pct,
       ROUND(100.0 * ama / NULLIF(SUM(ama) OVER (
             PARTITION BY broadcast_date, platform, daypart), 0), 2)     AS share_pct,
       ROUND(weighted_minutes / NULLIF(reach_persons, 0), 1)             AS avg_min_per_viewer,
       (sample_viewers < 30)                                             AS low_sample_flag
FROM t;

CREATE OR REPLACE VIEW mart.v_weekly_cross_platform AS
SELECT week_start, brand_id, brand_name,
       SUM(universe)                     AS universe,
       SUM(reach_tv)                     AS reach_tv,
       SUM(reach_digital)                AS reach_digital,
       SUM(reach_mobile)                 AS reach_mobile,
       SUM(reach_ott)                    AS reach_ott,
       SUM(reach_total_unduplicated)     AS reach_total_unduplicated,
       SUM(reach_tv_only)                AS reach_tv_only,
       SUM(reach_digital_only)           AS reach_digital_only,
       SUM(reach_tv_and_digital)         AS reach_tv_and_digital,
       ROUND(100.0 * SUM(reach_total_unduplicated) / SUM(universe), 2) AS reach_pct,
       ROUND(100.0 * (SUM(reach_tv) + SUM(reach_digital) + SUM(reach_mobile) + SUM(reach_ott)
                      - SUM(reach_total_unduplicated))
             / NULLIF(SUM(reach_total_unduplicated), 0), 2)            AS duplication_pct
FROM mart.weekly_cross_platform_reach
GROUP BY 1, 2, 3;
