#!/usr/bin/env bash
# ---------------------------------------------------------------------
# common.sh - shared settings and helpers. Every script sources this.
# ---------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR

# Load settings from .env if present (copy .env.example -> .env).
# Variables already set in the environment win (Docker / Airflow set their own).
if [[ -f "$PROJECT_DIR/.env" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key//$'\r'/}"; value="${value//$'\r'/}"        # tolerate Windows line endings
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi
    done < "$PROJECT_DIR/.env"
fi

# Database connection - psql reads these PG* variables automatically
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-audience}"

# Pipeline settings
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/data}"
EXPORT_DIR="${EXPORT_DIR:-$PROJECT_DIR/exports}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
QUALIFIER_SEC="${QUALIFIER_SEC:-60}"          # min seconds viewed to count as reached
MAX_SESSION_MIN="${MAX_SESSION_MIN:-240}"     # "TV left on" cap
PYTHON="${PYTHON:-python3}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
export RUN_ID

mkdir -p "$LOG_DIR" "$EXPORT_DIR"
LOG_FILE="$LOG_DIR/pipeline_$(date +%Y%m%d).log"

log() {
    local level="$1"; shift
    printf '%s [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE" >&2
}

die() { log ERROR "$*"; exit 1; }

# Run psql: no ~/.psqlrc (-X), stop on first error, quiet
psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# Run a .sql file with variables: run_sql file.sql run_date=2026-09-17 ...
run_sql() {
    local file="$1"; shift
    local args=(-v "qualifier_sec=$QUALIFIER_SEC" -v "max_session_min=$MAX_SESSION_MIN" -v "run_id=$RUN_ID")
    for kv in "$@"; do args+=(-v "$kv"); done
    [[ -f "$file" ]] || die "SQL file not found: $file"
    log INFO "sql  $(basename "$file") $*"
    psql_q "${args[@]}" -f "$file"
}

# Validate a YYYY-MM-DD date (also blocks SQL injection through arguments)
require_date() {
    local d="${1:-}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Expected date YYYY-MM-DD, got '$d'"
    date -d "$d" +%F >/dev/null 2>&1 || die "Invalid calendar date: $d"
}

# Monday of the ISO week containing a date
week_start_of() { date -d "$1 -$(( $(date -d "$1" +%u) - 1 )) days" +%F; }

# Record step status in audit.pipeline_runs
audit_step() {
    local step="$1" run_date="$2" status="$3" msg="${4:-}"
    psql_q -c "INSERT INTO audit.pipeline_runs (run_id, step, run_date, status, message)
               VALUES ('$RUN_ID', '$step', '$run_date', '$status', \$msg\$${msg}\$msg\$);" \
        >/dev/null 2>&1 || true
}
