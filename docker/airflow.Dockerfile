# Airflow image + the tools the pipeline's shell scripts need (psql, pandas)
FROM apache/airflow:3.1.8

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*

USER airflow
# pin Airflow so installing pandas never upgrades/downgrades it
RUN pip install --no-cache-dir "apache-airflow==3.1.8" pandas numpy matplotlib
