"""
Airflow DAG: daily audience-measurement pipeline.

One DAG run = one broadcast day ({{ ds }}). Each task calls a shell script in
bin/, so the exact same steps run with or without Airflow.

    check_files -> load_raw -> stage -> dq_staging
      -> daily_weights -> dq_daily_weights -> daily_marts -> dq_daily_marts
      -> is_sunday? -> weekly_weights -> dq_weekly_weights
                    -> weekly_marts -> dq_weekly_marts
      -> export

Design choices worth explaining in an interview:
* max_active_runs=1: weekly numbers need all 7 days, so days run in order.
* check_files retries for ~3 hours: meter files can arrive late.
* Any failed ERROR-level data-quality check fails its task, so nothing
  downstream (marts, exports) is built on bad data.
* Weekly tasks only run on Sundays (ShortCircuitOperator).
* Gotcha: BashOperator treats a command ending in ".sh" as a Jinja template
  FILE. Our commands end with an argument, so that never happens.

Works on Airflow 2.x and 3.x (imports below try both locations).
"""
import os
from datetime import timedelta

import pendulum
from airflow import DAG

try:  # Airflow 3
    from airflow.providers.standard.operators.bash import BashOperator
    from airflow.providers.standard.operators.python import ShortCircuitOperator
except ImportError:  # Airflow 2
    from airflow.operators.bash import BashOperator
    from airflow.operators.python import ShortCircuitOperator

PROJECT_DIR = os.environ.get("PROJECT_DIR", "/opt/project")
BIN = f"{PROJECT_DIR}/bin"
DS = "{{ ds }}"
# Monday of the week that ends on this Sunday
WEEK_START = "{{ macros.ds_add(ds, -6) }}"

default_args = {
    "owner": "audience-analytics",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}


def is_week_end(ds: str, **_) -> bool:
    """Continue to the weekly tasks only when this broadcast day is a Sunday."""
    return pendulum.parse(ds).day_of_week == pendulum.SUNDAY


with DAG(
    dag_id="audience_measurement_daily",
    description="Load, clean, weight and report daily TV + digital panel data",
    start_date=pendulum.datetime(2026, 8, 31, tz="UTC"),   # UTC so {{ ds }} = broadcast date
    end_date=pendulum.datetime(2026, 9, 27, tz="UTC"),     # demo data range
    schedule="@daily",
    catchup=True,            # run every day in the range when the DAG is switched on
    max_active_runs=1,
    default_args=default_args,
    tags=["audience", "panel", "etl"],
) as dag:

    check_files = BashOperator(
        task_id="check_files",
        bash_command=f'test -f "{PROJECT_DIR}/data/raw/viewing/viewing_events_{DS}.csv" '
                     f'&& test -f "{PROJECT_DIR}/data/raw/intab/intab_{DS}.csv"',
        retries=6,
        retry_delay=timedelta(minutes=30),
    )

    load_raw = BashOperator(task_id="load_raw", bash_command=f"bash {BIN}/load_raw.sh {DS}")
    stage = BashOperator(task_id="stage", bash_command=f"bash {BIN}/stage.sh {DS}")
    dq_staging = BashOperator(task_id="dq_staging",
                              bash_command=f"bash {BIN}/dq_check.sh staging {DS}", retries=0)

    daily_weights = BashOperator(task_id="daily_weights",
                                 bash_command=f"bash {BIN}/compute_weights.sh daily {DS}")
    dq_daily_weights = BashOperator(task_id="dq_daily_weights",
                                    bash_command=f"bash {BIN}/dq_check.sh weights_daily {DS}",
                                    retries=0)

    daily_marts = BashOperator(task_id="daily_marts",
                               bash_command=f"bash {BIN}/build_marts.sh daily {DS}")
    dq_daily_marts = BashOperator(task_id="dq_daily_marts",
                                  bash_command=f"bash {BIN}/dq_check.sh daily_mart {DS}", retries=0)

    sunday = ShortCircuitOperator(
        task_id="is_week_end",
        python_callable=is_week_end,
        ignore_downstream_trigger_rules=False,  # skip weekly tasks only, not export
    )

    weekly_weights = BashOperator(task_id="weekly_weights",
                                  bash_command=f"bash {BIN}/compute_weights.sh weekly {WEEK_START}")
    dq_weekly_weights = BashOperator(task_id="dq_weekly_weights",
                                     bash_command=f"bash {BIN}/dq_check.sh weights_weekly {WEEK_START}",
                                     retries=0)
    weekly_marts = BashOperator(task_id="weekly_marts",
                                bash_command=f"bash {BIN}/build_marts.sh weekly {WEEK_START}")
    dq_weekly_marts = BashOperator(task_id="dq_weekly_marts",
                                   bash_command=f"bash {BIN}/dq_check.sh weekly_mart {WEEK_START}",
                                   retries=0)

    export = BashOperator(
        task_id="export",
        bash_command=f"bash {BIN}/export_marts.sh ",   # trailing space: see .sh gotcha above
        trigger_rule="none_failed_min_one_success",
    )

    (check_files >> load_raw >> stage >> dq_staging
     >> daily_weights >> dq_daily_weights >> daily_marts >> dq_daily_marts >> sunday
     >> weekly_weights >> dq_weekly_weights >> weekly_marts >> dq_weekly_marts >> export)
    dq_daily_marts >> export
