# SOP: Daily Audience Measurement Pipeline

| | |
|---|---|
| **Purpose** | Produce daily and weekly audience estimates from panel meter data, and stop bad data before it reaches reports. |
| **Scope** | Daily viewing + in-tab files, panel weighting, daily/weekly marts, CSV exports for Power BI/Excel. |
| **Run frequency** | Daily, one run per broadcast day. Weekly outputs on Sundays. |
| **Owner** | Data analyst on duty |
| **Version** | 1.0 |

---

## 1. Roles

| Role | Responsibility |
|---|---|
| Analyst on duty | Runs/monitors the pipeline, reviews checks, investigates, restates. |
| Data operations (meter team) | Supplies daily files; confirms outages; sends late or corrected files. |
| Analytics lead | Approves waivers; approves publishing any day with open issues. |

## 2. Inputs

| File | Location | Expected |
|---|---|---|
| Viewing events | `data/raw/viewing/viewing_events_<YYYY-MM-DD>.csv` | ~5,500-6,000 rows/day |
| Meter status (in-tab) | `data/raw/intab/intab_<YYYY-MM-DD>.csv` | 1 row per household (1,200) |
| Late / restated files | same folders, suffix `_late` / `_restated` | only when Data ops sends them |
| Reference data | `data/raw/reference/*.csv` | changes rarely; see §9 |

A broadcast day runs **06:00 to 06:00** the next morning.

## 3. Before you start (one-time)

1. Postgres reachable (`pg_isready`), `psql` and Python installed, or Docker running (`docker compose up -d`).
2. `.env` set up from `.env.example`.
3. `bin/init_db.sh` runs without errors.

## 4. Daily run

### With Airflow (normal)

The DAG `audience_measurement_daily` runs every day. Check the Airflow UI:
all tasks green, or the weekly tasks pink (skipped) on Monday-Saturday.

### By hand

```bash
bin/run_pipeline.sh --date 2026-09-18
```

| # | Step | Command | Expected | If it fails |
|---|---|---|---|---|
| 1 | Files present | `ls data/raw/viewing/*2026-09-18*` | 1 viewing + 1 in-tab file | Wait; Airflow retries every 30 min for 3h. Then contact Data ops. |
| 2 | Load | `bin/load_raw.sh 2026-09-18` | row counts logged | Check file is valid CSV with header. |
| 3 | Stage | `bin/stage.sh 2026-09-18` | rejected rows by reason printed | Read the SQL error; usually a schema change in the file. |
| 4 | Staging checks | `bin/dq_check.sh staging 2026-09-18` | 0 errors | See §7. |
| 5 | Weights | `bin/compute_weights.sh daily 2026-09-18` | `converged True`, design effect < 2 | See §7. |
| 6 | Weight checks | `bin/dq_check.sh weights_daily 2026-09-18` | 0 errors | See §7. |
| 7 | Daily marts | `bin/build_marts.sh daily 2026-09-18` | TV reach table printed | |
| 8 | Mart checks | `bin/dq_check.sh daily_mart 2026-09-18` | 0 errors | See §7. |
| 9 | Weekly (Sundays) | weights, checks, marts, checks for the Monday of the week | 0 errors | Needs all 7 days staged. |
| 10 | Export | `bin/export_marts.sh` | CSVs in `exports/` | |

Every step is **idempotent**: it deletes its own output for that day first.
Re-running a step or a whole day is always safe.

## 5. Daily review (10 minutes)

1. Open the run summary at the end of the log, or:
   ```sql
   SELECT period, scope, severity, check_name, observed, threshold, details
   FROM audit.dq_results
   WHERE run_id = (SELECT max(run_id) FROM audit.dq_results) AND NOT passed;
   ```
2. For every **WARN**, decide: expected (note it), or investigate
   (`docs/INVESTIGATIONS.md` shows how).
3. Check panel health:
   `bin/run_query.sh sql/analysis/01_intab_by_region.sql exports/analysis/intab.csv start_date=<D-6> end_date=<D>`
4. Before sending any number, check its `sample_viewers`. Under 30 = do not
   report a change without a caveat.

## 6. Restating a day (late or corrected files)

Use when Data ops sends late or corrected files for a day already run (or
stopped).

1. Confirm with Data ops which day and which files.
2. Put the files in the normal folders. Keep their suffix (`_late`, `_restated`):
   ```bash
   cp data/late_delivery/viewing/*.csv data/raw/viewing/
   cp data/late_delivery/intab/*.csv   data/raw/intab/
   ```
   A `_restated` in-tab file overrides the original for the same household.
3. Re-run from that day. The day's week is rebuilt automatically when complete:
   ```bash
   bin/run_pipeline.sh --start 2026-09-17      # through the latest day
   bin/run_pipeline.sh --date  2026-09-17      # or only that day + its week
   ```
4. Confirm the check that failed now passes, and compare key numbers before
   vs after (`sql/analysis/02_region_reach_vs_last_week.sql`).
5. Tell report users which day changed and why.

## 7. Failure guide

| Check | Severity | Usual cause | Action |
|---|---|---|---|
| `stage_stats_present`, `sessions_present` | ERROR | Empty or wrong file | Check the file; ask Data ops to resend. |
| `invalid_row_rate_pct` > 3% | ERROR | Format change (new date format, renamed platform/brand) | `SELECT reason, raw_row FROM audit.rejected_events WHERE broadcast_date = '<D>' LIMIT 50;` Add an alias (§9) or ask for a fixed file. |
| `duplicate_rate_pct` > 3% | WARN | File sent twice | Duplicates are removed automatically. Tell Data ops. |
| `capped_session_rate_pct` > 2% | WARN | Meters left on / clock problem | Check which households; tell Data ops if concentrated. |
| `overall_intab_rate_pct` < 70% | ERROR | Wide meter outage | Contact Data ops. Do not publish. |
| `intab_critical_<region>` < 50% | ERROR | Regional meter outage | Ask Data ops for late data → §6. If none is coming, see §8. |
| `intab_rate_pct_<region>` < 75% | WARN | Partial outage | Watch the region's numbers; caveat them. |
| `raking_converged`, `sum_weights_vs_universe_pct`, `max_marginal_gap_pct` | ERROR | A demo group has no in-tab panelists | Check `mart.daily_intab_summary`; usually an outage. |
| `max_to_mean_weight_ratio`, `design_effect`, `ess_<region>` | WARN | Uneven in-tab | Treat regional numbers as low precision. |
| `grid_rows_complete`, `reach_pct_out_of_range`, `rating_above_reach_market`, `total_day_below_daypart`, `daypart_minutes_mismatch` | ERROR | Bug or reference-data change | Logic error - do not publish. Re-run the day; if it repeats, investigate the SQL. |
| `week_on_week_anomalies` | WARN | Real event, or data problem | Investigate: real events move all regions together and in-tab is normal (see `docs/INVESTIGATIONS.md`). Also fires the week *after* a big event. |
| Weekly checks (`unduplicated_*`, `venn_parts_add_up`, `frequency_out_of_range`) | ERROR | Logic error | Do not publish the week; re-run it. |

## 8. Waivers (publishing despite an ERROR)

Only when the analytics lead approves in writing (e.g. late data will never
arrive and the business needs the day).

```bash
DQ_WAIVE=intab_critical_east@2026-09-17 bin/run_pipeline.sh --date 2026-09-17
```

The check is stored as `WAIVED` in `audit.dq_results` so the decision is
traceable. Any regional number for the waived region must be marked as
unreliable in reports.

## 9. Reference data changes

| Change | How |
|---|---|
| New spelling of a brand in the feed | Add a row to `data/raw/reference/brand_aliases.csv` (lower-case, trimmed) → `bin/init_db.sh` → restate affected days (§6). |
| New platform spelling | Add to `sql/01_seed_reference.sql` → `bin/init_db.sh` → restate. |
| New brand | Add to `brands.csv`, `brand_platforms.csv`, `brand_aliases.csv` → `bin/init_db.sh`. |
| New universe estimates | Replace `universe_estimates.csv` → `bin/init_db.sh` → restate from the effective date. |
| Panel changes (new / left households) | Replace `households.csv`, `panelists.csv` → `bin/init_db.sh`. |

Note: `init_db.sh` reloads all reference data in one transaction.

## 10. Running on AWS (optional)

| Local | AWS |
|---|---|
| `data/raw/` folders | S3 bucket, e.g. `s3://<bucket>/raw/viewing/` |
| Postgres in Docker | Amazon RDS for PostgreSQL |
| Airflow standalone | Amazon MWAA, or Airflow on one EC2 instance |
| `.env` passwords | AWS Secrets Manager |

Change needed: `load_raw.sh` first copies the day's files from S3
(`aws s3 cp s3://<bucket>/raw/viewing/ ... --recursive --exclude "*" --include "*<date>*"`),
then loads as today. Set `PGHOST` to the RDS endpoint. Nothing else changes.

## 11. Outputs

| Output | Used by |
|---|---|
| `exports/daily_brand_daypart.csv` | Power BI daily dashboard, Excel reports |
| `exports/daily_brand_daypart_demo.csv` + `dim_*.csv` | Power BI model with demo slicers |
| `exports/weekly_*` | Weekly reach & cross-platform pages |
| `exports/dq_results.csv`, `stage_stats.csv`, `weighting_diagnostics.csv` | Data-quality page |
| `exports/analysis/*.csv` | Investigations, ad-hoc questions |

Power BI can also connect directly to the Postgres `mart` schema
(localhost:5432, database `audience`).

## 12. Change log

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-10 | First version |
