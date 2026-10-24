#!/usr/bin/env bash
# ---------------------------------------------------------------------
# compute_weights.sh - weight the in-tab panel to the universe.
# Usage: bin/compute_weights.sh daily  2026-09-17
#        bin/compute_weights.sh weekly 2026-09-14   (Monday of the week)
#
# Flow (SQL -> shell -> Python -> SQL):
#   1. export in-tab respondents + universe from Postgres to CSV
#   2. scripts/rake_weights.py computes weights
#   3. load weights + diagnostics back into Postgres
# Weekly sample = panelists in-tab on at least MIN_WEEKLY_INTAB_DAYS of 7.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

MODE="${1:-}"; PERIOD="${2:-}"
require_date "$PERIOD"
MIN_WEEKLY_INTAB_DAYS="${MIN_WEEKLY_INTAB_DAYS:-5}"

case "$MODE" in
  daily)
    RESP_SQL="SELECT p.panelist_id, p.age_group, p.gender, p.region
              FROM stg.daily_intab i JOIN ref.panelists p USING (panelist_id)
              WHERE i.broadcast_date = '$PERIOD' AND i.is_intab"
    TARGET=stg.daily_weights; KEY=broadcast_date ;;
  weekly)
    [[ "$(date -d "$PERIOD" +%u)" == "1" ]] || die "Weekly period must start on a Monday: $PERIOD"
    days=$(psql_q -tAc "SELECT count(DISTINCT broadcast_date) FROM stg.daily_intab
                        WHERE broadcast_date BETWEEN '$PERIOD' AND date '$PERIOD' + 6")
    [[ "$days" == "7" ]] || die "Week $PERIOD has only $days staged days - need 7"
    RESP_SQL="SELECT p.panelist_id, p.age_group, p.gender, p.region
              FROM stg.daily_intab i JOIN ref.panelists p USING (panelist_id)
              WHERE i.broadcast_date BETWEEN '$PERIOD' AND date '$PERIOD' + 6
              GROUP BY 1, 2, 3, 4
              HAVING count(*) FILTER (WHERE i.is_intab) >= $MIN_WEEKLY_INTAB_DAYS"
    TARGET=stg.weekly_weights; KEY=week_start ;;
  *) die "Usage: compute_weights.sh daily|weekly YYYY-MM-DD" ;;
esac

audit_step "weights_$MODE" "$PERIOD" STARTED
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. export (single-line query: \copy needs it on one line)
psql_q -c "\copy ($(tr '\n' ' ' <<<"$RESP_SQL")) TO '$WORK/respondents.csv' WITH (FORMAT csv, HEADER true)"
psql_q -c "\copy (SELECT age_group, gender, region, universe FROM ref.universe_estimates) TO '$WORK/universe.csv' WITH (FORMAT csv, HEADER true)"

# 2. rake
"$PYTHON" "$PROJECT_DIR/scripts/rake_weights.py" \
    --respondents "$WORK/respondents.csv" --universe "$WORK/universe.csv" \
    --out "$WORK/weights.csv" --diag "$WORK/diag.csv" | tee -a "$LOG_FILE"

# 3. load back (one transaction - all or nothing)
psql_q <<SQL
BEGIN;
DELETE FROM $TARGET WHERE $KEY = '$PERIOD';
CREATE TEMP TABLE w (panelist_id text, weight numeric) ON COMMIT DROP;
\copy w FROM '$WORK/weights.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO $TARGET ($KEY, panelist_id, weight) SELECT '$PERIOD', panelist_id, weight FROM w;

CREATE TEMP TABLE d (n_respondents int, sum_weight numeric, min_weight numeric, max_weight numeric,
                     mean_weight numeric, eff_sample_size numeric, design_effect numeric,
                     iterations int, n_trimmed int, converged boolean) ON COMMIT DROP;
\copy d FROM '$WORK/diag.csv' WITH (FORMAT csv, HEADER true)
DELETE FROM audit.weighting_diagnostics WHERE period_type = '$MODE' AND period_start = '$PERIOD';
INSERT INTO audit.weighting_diagnostics
       (period_type, period_start, n_respondents, sum_weight, min_weight, max_weight, mean_weight,
        eff_sample_size, design_effect, iterations, n_trimmed, converged)
SELECT '$MODE', '$PERIOD', * FROM d;
COMMIT;
SQL

audit_step "weights_$MODE" "$PERIOD" SUCCESS
log INFO "weights $MODE $PERIOD loaded into $TARGET"
