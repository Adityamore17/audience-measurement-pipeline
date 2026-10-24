#!/usr/bin/env bash
# ---------------------------------------------------------------------
# dq_check.sh - run data-quality checks; exit 1 if any ERROR check fails.
# Usage: bin/dq_check.sh staging        2026-09-17
#        bin/dq_check.sh weights_daily  2026-09-17
#        bin/dq_check.sh daily_mart     2026-09-17
#        bin/dq_check.sh weights_weekly 2026-09-14
#        bin/dq_check.sh weekly_mart    2026-09-14
# Results are stored in audit.dq_results (one row per check).
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

SCOPE="${1:-}"; PERIOD="${2:-}"
require_date "$PERIOD"
DQ="$PROJECT_DIR/sql/dq"

case "$SCOPE" in
  staging)        run_sql "$DQ/dq_staging.sql"     "run_date=$PERIOD" ;;
  weights_daily)  run_sql "$DQ/dq_weights.sql"     "period=$PERIOD" "period_type=daily" ;;
  weights_weekly) run_sql "$DQ/dq_weights.sql"     "period=$PERIOD" "period_type=weekly" ;;
  daily_mart)     run_sql "$DQ/dq_daily_mart.sql"  "run_date=$PERIOD" ;;
  weekly_mart)    run_sql "$DQ/dq_weekly_mart.sql" "week_start=$PERIOD" ;;
  *) die "Unknown scope '$SCOPE'" ;;
esac

WHERE="run_id = '$RUN_ID' AND scope = '$SCOPE' AND period = '$PERIOD'"

# Waivers (needs sign-off, see SOP): DQ_WAIVE="check_name@YYYY-MM-DD,..."
# A waived ERROR is kept in audit.dq_results with severity WAIVED.
if [[ -n "${DQ_WAIVE:-}" ]]; then
    IFS=',' read -ra waivers <<< "$DQ_WAIVE"
    for item in "${waivers[@]}"; do
        [[ "$item" =~ ^([a-z0-9_]+)@([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]] \
            || die "Bad DQ_WAIVE entry '$item' (use check_name@YYYY-MM-DD)"
        [[ "${BASH_REMATCH[2]}" == "$PERIOD" ]] || continue
        n=$(psql_q -tAc "WITH u AS (
                UPDATE audit.dq_results
                   SET severity = 'WAIVED', details = details || ' [WAIVED via DQ_WAIVE]'
                 WHERE $WHERE AND check_name = '${BASH_REMATCH[1]}'
                   AND NOT passed AND severity = 'ERROR'
                RETURNING 1) SELECT count(*) FROM u")
        if (( n > 0 )); then log WARN "dq $SCOPE $PERIOD: ${BASH_REMATCH[1]} WAIVED"; fi
    done
fi

# print failed checks
psql_q -tA -F ' | ' -c "SELECT severity, check_name, observed, threshold, details
                         FROM audit.dq_results WHERE $WHERE AND NOT passed
                         ORDER BY severity, check_name" |
while IFS= read -r line; do
    [[ -n "$line" ]] && log WARN "dq $SCOPE $PERIOD: $line"
done

errors=$(psql_q -tAc "SELECT count(*) FROM audit.dq_results WHERE $WHERE AND NOT passed AND severity = 'ERROR'")
warns=$(psql_q -tAc  "SELECT count(*) FROM audit.dq_results WHERE $WHERE AND NOT passed AND severity = 'WARN'")
total=$(psql_q -tAc  "SELECT count(*) FROM audit.dq_results WHERE $WHERE")

if (( errors > 0 )); then
    audit_step "dq_$SCOPE" "$PERIOD" FAILED "$errors error(s)"
    die "dq $SCOPE $PERIOD: $errors ERROR check(s) failed - pipeline stopped"
fi
audit_step "dq_$SCOPE" "$PERIOD" SUCCESS "$total checks, $warns warning(s)"
log INFO "dq $SCOPE $PERIOD: $total checks run, 0 errors, $warns warning(s)"
