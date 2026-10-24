#!/usr/bin/env bash
# ---------------------------------------------------------------------
# load_raw.sh - land one broadcast day's files into the raw schema.
# Usage: bin/load_raw.sh 2026-09-17
#
# Loads every file for that date, including late deliveries:
#   data/raw/viewing/viewing_events_<date>*.csv
#   data/raw/intab/intab_<date>*.csv
# Idempotent: rows from the same file name are deleted before re-loading,
# so running it twice never doubles the data.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

RUN_DATE="${1:-}"; require_date "$RUN_DATE"
audit_step load_raw "$RUN_DATE" STARTED

shopt -s nullglob
viewing_files=("$DATA_DIR"/raw/viewing/viewing_events_"$RUN_DATE"*.csv)
intab_files=("$DATA_DIR"/raw/intab/intab_"$RUN_DATE"*.csv)
(( ${#viewing_files[@]} > 0 )) || { audit_step load_raw "$RUN_DATE" FAILED "no viewing file"; die "No viewing file for $RUN_DATE"; }
(( ${#intab_files[@]} > 0 ))   || { audit_step load_raw "$RUN_DATE" FAILED "no intab file";   die "No intab file for $RUN_DATE"; }

load_file() {   # load_file <target table> <column list> <path>
    local table="$1" cols="$2" path="$3" name
    name="$(basename "$path")"
    # one psql session = one transaction; temp table avoids clashes between parallel runs
    psql_q <<SQL
BEGIN;
CREATE TEMP TABLE landing ($(sed 's/,/ text,/g' <<<"$cols") text) ON COMMIT DROP;
\copy landing ($cols) FROM '$path' WITH (FORMAT csv, HEADER true)
DELETE FROM $table WHERE source_file = '$name';
INSERT INTO $table ($cols, source_file) SELECT $cols, '$name' FROM landing;
COMMIT;
SQL
    local n
    n=$(psql_q -tAc "SELECT count(*) FROM $table WHERE source_file = '$name'")
    log INFO "load $name -> $table ($n rows)"
}

for f in "${viewing_files[@]}"; do
    load_file raw.viewing_events "event_id,panelist_id,household_id,platform,brand,start_ts,end_ts" "$f"
done
for f in "${intab_files[@]}"; do
    load_file raw.intab "household_id,broadcast_date,meter_status" "$f"
done

audit_step load_raw "$RUN_DATE" SUCCESS "${#viewing_files[@]} viewing + ${#intab_files[@]} intab files"
