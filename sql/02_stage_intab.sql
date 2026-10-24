-- =====================================================================
-- 02_stage_intab.sql  -  who in the panel is usable ("in-tab") on a day
-- Variables: run_date
--
-- A household's meter reports OK / NO_DATA / FAULTY each day. Only
-- panelists in OK households are "in-tab" and get a weight.
-- If a restated file exists for the day, it wins over the original.
-- Households missing from every file are treated as MISSING (not in-tab).
-- =====================================================================
BEGIN;

DELETE FROM stg.daily_intab WHERE broadcast_date = :'run_date'::date;

WITH latest_status AS (
    SELECT DISTINCT ON (household_id)
           household_id,
           upper(trim(meter_status)) AS meter_status
    FROM raw.intab
    WHERE source_file LIKE 'intab_' || :'run_date' || '%'
    ORDER BY household_id,
             (source_file LIKE '%restated%') DESC,   -- restatement first
             loaded_at DESC
)
INSERT INTO stg.daily_intab (broadcast_date, panelist_id, household_id, meter_status, is_intab)
SELECT :'run_date'::date,
       p.panelist_id,
       p.household_id,
       COALESCE(s.meter_status, 'MISSING'),
       COALESCE(s.meter_status, 'MISSING') = 'OK'
FROM ref.panelists p
LEFT JOIN latest_status s USING (household_id);

COMMIT;

SELECT meter_status, count(*) AS panelists
FROM stg.daily_intab
WHERE broadcast_date = :'run_date'::date
GROUP BY 1 ORDER BY 2 DESC;
