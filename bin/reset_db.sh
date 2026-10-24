#!/usr/bin/env bash
# ---------------------------------------------------------------------
# reset_db.sh - DELETE everything the pipeline created in the database.
# Usage: bin/reset_db.sh --yes
# Use only to start from scratch on your own machine.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

[[ "${1:-}" == "--yes" ]] || die "This drops all pipeline schemas in '$PGDATABASE'. Re-run with --yes"
psql_q -c "DROP SCHEMA IF EXISTS mart, stg, raw, ref, audit CASCADE;"
log INFO "Dropped schemas raw, ref, stg, mart, audit in $PGDATABASE"
