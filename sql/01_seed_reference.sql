-- =====================================================================
-- 01_seed_reference.sql  -  static lookup data (safe to re-run)
-- Brand / panel / universe CSVs are loaded by bin/init_db.sh.
-- =====================================================================

INSERT INTO ref.platform_aliases (alias_norm, platform) VALUES
    ('tv', 'TV'), ('linear tv', 'TV'), ('television', 'TV'),
    ('digital', 'Digital'), ('desktop', 'Digital'), ('web', 'Digital'),
    ('mobile', 'Mobile'), ('smartphone', 'Mobile'), ('app', 'Mobile'),
    ('ott', 'OTT'), ('ctv', 'OTT'), ('connected tv', 'OTT')
ON CONFLICT (alias_norm) DO UPDATE SET platform = EXCLUDED.platform;

INSERT INTO ref.dayparts (daypart, start_offset_min, end_offset_min, sort_order) VALUES
    ('Total Day',     0, 1440, 0),   -- 06:00 - 06:00
    ('Morning',       0,  360, 1),   -- 06:00 - 12:00
    ('Daytime',     360,  720, 2),   -- 12:00 - 18:00
    ('Prime Time',  720, 1020, 3),   -- 18:00 - 23:00
    ('Late Night', 1020, 1440, 4)    -- 23:00 - 06:00
ON CONFLICT (daypart) DO UPDATE
   SET start_offset_min = EXCLUDED.start_offset_min,
       end_offset_min   = EXCLUDED.end_offset_min,
       sort_order       = EXCLUDED.sort_order;
