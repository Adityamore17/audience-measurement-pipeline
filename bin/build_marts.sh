#!/usr/bin/env bash
# ---------------------------------------------------------------------
# build_marts.sh - build reporting tables.
# Usage: bin/build_marts.sh daily  2026-09-17
#        bin/build_marts.sh weekly 2026-09-14   (Monday of the week)
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

MODE="${1:-}"; PERIOD="${2:-}"
require_date "$PERIOD"
audit_step "mart_$MODE" "$PERIOD" STARTED

case "$MODE" in
  daily)  run_sql "$PROJECT_DIR/sql/04_mart_daily.sql"  "run_date=$PERIOD" ;;
  weekly) run_sql "$PROJECT_DIR/sql/05_mart_weekly.sql" "week_start=$PERIOD" ;;
  *) die "Usage: build_marts.sh daily|weekly YYYY-MM-DD" ;;
esac

audit_step "mart_$MODE" "$PERIOD" SUCCESS
