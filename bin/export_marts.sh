#!/usr/bin/env bash
# ---------------------------------------------------------------------
# export_marts.sh - export reporting tables to CSV for Power BI / Excel.
# Usage: bin/export_marts.sh
# Output: exports/*.csv (overwritten each run)
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

export_table() {   # export_table <file name> <query>
    local name="$1" query="$2"
    psql_q -c "\copy ($query) TO '$EXPORT_DIR/$name.csv' WITH (FORMAT csv, HEADER true)"
    log INFO "export $name.csv ($(( $(wc -l < "$EXPORT_DIR/$name.csv") - 1 )) rows)"
}

export_table daily_brand_daypart_demo "SELECT * FROM mart.daily_brand_daypart_demo ORDER BY 1,2,3,5,6,7,8"
export_table daily_brand_daypart      "SELECT * FROM mart.v_daily_brand_daypart ORDER BY 1,2,3,5"
export_table daily_intab_summary      "SELECT * FROM mart.daily_intab_summary ORDER BY 1,2,3,4"
export_table weekly_brand_reach_demo  "SELECT * FROM mart.weekly_brand_reach_demo ORDER BY 1,2,3,5,6,7"
export_table weekly_cross_platform_demo "SELECT * FROM mart.weekly_cross_platform_reach ORDER BY 1,2,4,5,6"
export_table weekly_cross_platform    "SELECT * FROM mart.v_weekly_cross_platform ORDER BY 1,2"
export_table dim_universe             "SELECT * FROM ref.universe_estimates ORDER BY 1,2,3"
export_table dim_brands               "SELECT * FROM ref.brands ORDER BY 1"
export_table dim_dayparts             "SELECT * FROM ref.dayparts ORDER BY sort_order"
export_table dq_results               "SELECT * FROM audit.dq_results WHERE run_id = (SELECT max(run_id) FROM audit.dq_results) ORDER BY period, scope, check_name"
export_table weighting_diagnostics    "SELECT * FROM audit.weighting_diagnostics ORDER BY 1,2"
export_table stage_stats              "SELECT * FROM audit.stage_stats ORDER BY 1"

log INFO "exports written to $EXPORT_DIR"
