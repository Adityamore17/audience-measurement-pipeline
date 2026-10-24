#!/usr/bin/env bash
# ---------------------------------------------------------------------
# run_analysis.sh - run the investigation/report queries into CSVs.
# Usage: bin/run_analysis.sh
# Output: exports/analysis/*.csv
# Each line below is one SQL file turned into a repeatable shell job.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"
Q="$PROJECT_DIR/sql/analysis"; OUT="$EXPORT_DIR/analysis"; R="$PROJECT_DIR/bin/run_query.sh"

bash "$R" "$Q/01_intab_by_region.sql"          "$OUT/intab_by_region.csv"        start_date=2026-09-14 end_date=2026-09-20
bash "$R" "$Q/02_region_reach_vs_last_week.sql" "$OUT/east_reach_2026-09-17.csv"  run_date=2026-09-17 region=East
bash "$R" "$Q/03_brand_daily_trend.sql"        "$OUT/tv_daily_trend.csv"         platform=TV
bash "$R" "$Q/04_daypart_vs_baseline.sql"      "$OUT/playmax_2026-09-20.csv"     run_date=2026-09-20 brand=PlayMax
bash "$R" "$Q/05_weekly_reach_frequency.sql"   "$OUT/weekly_reach_frequency.csv"
bash "$R" "$Q/06_cross_platform_by_age.sql"    "$OUT/cross_platform_by_age.csv"  week_start=2026-09-21
bash "$R" "$Q/07_rejections_by_reason.sql"     "$OUT/rejections_by_reason.csv"
