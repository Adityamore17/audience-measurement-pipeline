#!/usr/bin/env bash
# ---------------------------------------------------------------------
# run_query.sh - turn any SQL query file into a scheduled/automatable job.
# Runs a .sql file with variables and writes the result to CSV.
#
# Usage: bin/run_query.sh <query.sql> <output.csv> [name=value ...]
# Example:
#   bin/run_query.sh sql/analysis/top_brands.sql exports/top_brands.csv run_date=2026-09-20
#
# Inside the .sql file use :'run_date' (quoted) or :limit (unquoted).
# The file must end with ONE SELECT - that is what gets exported.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

QUERY="${1:-}"; OUT="${2:-}"; shift 2 || true
[[ -f "$QUERY" ]] || die "Usage: run_query.sh <query.sql> <output.csv> [name=value ...]"
[[ -n "$OUT" ]]   || die "Missing output path"

args=(-v "qualifier_sec=$QUALIFIER_SEC" -v "run_id=$RUN_ID")
for kv in "$@"; do
    [[ "$kv" =~ ^[a-z_]+=[A-Za-z0-9_.:-]+$ ]] || die "Bad variable '$kv' (use name=value)"
    args+=(-v "$kv")
done

mkdir -p "$(dirname "$OUT")"
tmp="$OUT.tmp"
psql -X -v ON_ERROR_STOP=1 --csv "${args[@]}" -f "$QUERY" > "$tmp"
mv "$tmp" "$OUT"
log INFO "query $(basename "$QUERY") -> $OUT ($(( $(wc -l < "$OUT") - 1 )) rows)"
