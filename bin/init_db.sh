#!/usr/bin/env bash
# ---------------------------------------------------------------------
# init_db.sh - create the database objects and (re)load reference data.
# Usage: bin/init_db.sh
# Safe to re-run: tables are created IF NOT EXISTS, reference data is
# replaced inside one transaction.
# ---------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

REF="$DATA_DIR/raw/reference"
for f in households panelists universe_estimates brands brand_platforms brand_aliases; do
    [[ -f "$REF/$f.csv" ]] || die "Missing $REF/$f.csv - run scripts/generate_panel_data.py first"
done

# Create the database if it does not exist yet
if ! psql_q -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1; then
    log INFO "Creating database $PGDATABASE"
    psql_q -d postgres -c "CREATE DATABASE \"$PGDATABASE\""
fi

run_sql "$PROJECT_DIR/sql/00_schema.sql"
run_sql "$PROJECT_DIR/sql/01_seed_reference.sql"

log INFO "Loading reference data from $REF"
psql_q <<SQL
BEGIN;
TRUNCATE ref.brand_aliases, ref.brand_platforms, ref.brands,
         ref.panelists, ref.households, ref.universe_estimates;
\copy ref.households         FROM '$REF/households.csv'         WITH (FORMAT csv, HEADER true)
\copy ref.panelists          FROM '$REF/panelists.csv'          WITH (FORMAT csv, HEADER true)
\copy ref.universe_estimates FROM '$REF/universe_estimates.csv' WITH (FORMAT csv, HEADER true)
\copy ref.brands             FROM '$REF/brands.csv'             WITH (FORMAT csv, HEADER true)
\copy ref.brand_platforms    FROM '$REF/brand_platforms.csv'    WITH (FORMAT csv, HEADER true)
\copy ref.brand_aliases      FROM '$REF/brand_aliases.csv'      WITH (FORMAT csv, HEADER true)
COMMIT;
SQL

psql_q -c "SELECT 'households' AS t, count(*) FROM ref.households
           UNION ALL SELECT 'panelists', count(*) FROM ref.panelists
           UNION ALL SELECT 'universe cells', count(*) FROM ref.universe_estimates
           UNION ALL SELECT 'brands', count(*) FROM ref.brands;"
log INFO "Database ready"
