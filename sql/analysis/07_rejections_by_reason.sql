-- Data-quality trend: rejected raw rows per day and reason.
-- Vars: none
-- Run : bin/run_query.sh sql/analysis/07_rejections_by_reason.sql exports/analysis/rejections.csv
SELECT s.broadcast_date,
       s.raw_rows,
       COUNT(*) FILTER (WHERE r.reason = 'DUPLICATE')             AS duplicate,
       COUNT(*) FILTER (WHERE r.reason = 'NON_POSITIVE_DURATION') AS non_positive_duration,
       COUNT(*) FILTER (WHERE r.reason = 'UNKNOWN_BRAND')         AS unknown_brand,
       COUNT(*) FILTER (WHERE r.reason = 'UNKNOWN_PLATFORM')      AS unknown_platform,
       COUNT(*) FILTER (WHERE r.reason = 'BAD_TIMESTAMP')         AS bad_timestamp,
       COUNT(*) FILTER (WHERE r.reason = 'ORPHAN_PANELIST')       AS orphan_panelist,
       ROUND(100.0 * COUNT(r.reason) / s.raw_rows, 2)             AS total_rejected_pct
FROM audit.stage_stats s
LEFT JOIN audit.rejected_events r USING (broadcast_date)
GROUP BY s.broadcast_date, s.raw_rows
ORDER BY s.broadcast_date;
