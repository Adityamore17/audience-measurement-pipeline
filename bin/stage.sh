#!/usr/bin/env bash
# ---------------------------------------------------------------------
# stage.sh - build the clean staging layer for one broadcast day.
# Usage: bin/stage.sh 2026-09-17
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

RUN_DATE="${1:-}"; require_date "$RUN_DATE"
audit_step stage "$RUN_DATE" STARTED

run_sql "$PROJECT_DIR/sql/02_stage_intab.sql"   "run_date=$RUN_DATE"
run_sql "$PROJECT_DIR/sql/03_stage_viewing.sql" "run_date=$RUN_DATE"

stats=$(psql_q -tAc "SELECT format('raw=%s rejected=%s duplicates=%s sessions=%s merged=%s capped=%s',
                       raw_rows, rejected_rows, duplicate_rows, sessions, merged_fragments, capped_sessions)
                     FROM audit.stage_stats WHERE broadcast_date = '$RUN_DATE'")
log INFO "stage $RUN_DATE: $stats"
audit_step stage "$RUN_DATE" SUCCESS "$stats"
