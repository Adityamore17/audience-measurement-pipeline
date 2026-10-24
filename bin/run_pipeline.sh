#!/usr/bin/env bash
# ---------------------------------------------------------------------
# run_pipeline.sh - run the whole pipeline without Airflow.
#
# Usage:
#   bin/run_pipeline.sh                         all days that have raw files
#   bin/run_pipeline.sh --date 2026-09-17       one day (+ its week if complete)
#   bin/run_pipeline.sh --start 2026-09-17      that day to the latest file
#   bin/run_pipeline.sh --start 2026-09-14 --end 2026-09-20
#
# Per day : load_raw -> stage -> dq -> daily weights -> dq -> daily mart -> dq
# Per week: weekly weights -> dq -> weekly mart -> dq   (only complete weeks)
# Finally : export CSVs + print a data-quality summary
# Any ERROR stops the run (set -e). Every step is safe to re-run.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"
BIN="$PROJECT_DIR/bin"

START=""; END=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)  START="$2"; END="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --end)   END="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "Unknown option $1" ;;
    esac
done

# Default range = every date that has a viewing file
mapfile -t ALL < <(ls "$DATA_DIR"/raw/viewing/ 2>/dev/null \
    | sed -nE 's/^viewing_events_([0-9]{4}-[0-9]{2}-[0-9]{2}).*\.csv$/\1/p' | sort -u)
(( ${#ALL[@]} > 0 )) || die "No raw files in $DATA_DIR/raw/viewing"
START="${START:-${ALL[0]}}"
END="${END:-${ALL[-1]}}"     # --start alone = from that day to the latest file
require_date "$START"; require_date "$END"

log INFO "===== pipeline run $RUN_ID: $START -> $END ====="
bash "$BIN/init_db.sh"

process_day() {
    local d="$1"
    log INFO "----- day $d -----"
    bash "$BIN/load_raw.sh" "$d"
    bash "$BIN/stage.sh" "$d"
    bash "$BIN/dq_check.sh" staging "$d"
    bash "$BIN/compute_weights.sh" daily "$d"
    bash "$BIN/dq_check.sh" weights_daily "$d"
    bash "$BIN/build_marts.sh" daily "$d"
    bash "$BIN/dq_check.sh" daily_mart "$d"
}

process_week() {
    local w="$1"
    log INFO "----- week $w -----"
    bash "$BIN/compute_weights.sh" weekly "$w"
    bash "$BIN/dq_check.sh" weights_weekly "$w"
    bash "$BIN/build_marts.sh" weekly "$w"
    bash "$BIN/dq_check.sh" weekly_mart "$w"
}

week_if_complete() {   # build a week only when all 7 days are staged
    local w="$1" staged
    staged=$(psql_q -tAc "SELECT count(DISTINCT broadcast_date) FROM stg.daily_intab
                          WHERE broadcast_date BETWEEN '$w' AND date '$w' + 6")
    if [[ "$staged" == "7" ]]; then
        process_week "$w"
    else
        log WARN "week $w has $staged/7 days staged - weekly numbers skipped"
    fi
}

declare -A PENDING_WEEKS=()
d="$START"
while [[ ! "$d" > "$END" ]]; do
    process_day "$d"
    w="$(week_start_of "$d")"
    if [[ "$(date -d "$d" +%u)" == "7" ]]; then     # Sunday closes the week
        week_if_complete "$w"
        unset 'PENDING_WEEKS[$w]'
    else
        PENDING_WEEKS["$w"]=1
    fi
    d=$(date -d "$d +1 day" +%F)
done

# weeks touched mid-week (e.g. a single restated day) are rebuilt if complete
for w in $(printf '%s\n' "${!PENDING_WEEKS[@]}" | sort); do
    week_if_complete "$w"
done

bash "$BIN/export_marts.sh"

log INFO "===== data-quality summary for run $RUN_ID ====="
psql_q -c "SELECT scope, period, severity, check_name, observed, threshold
           FROM audit.dq_results
           WHERE run_id = '$RUN_ID' AND NOT passed
           ORDER BY period, scope, check_name;"
log INFO "===== pipeline run $RUN_ID finished OK ====="
