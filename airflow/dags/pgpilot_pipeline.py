import os
from datetime import datetime, timedelta

import psycopg2
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

PROJECT_DIR = "/opt/pgpilot"

default_args = {
    "owner": "aaron",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}


def validate_load():
    """Fail the pipeline if the most recent load looks wrong, so we never
    back up a broken state. Reads the load_log row load_data.py writes."""
    conn = psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT rows_loaded, rows_rejected
                FROM load_log
                ORDER BY run_at DESC
                LIMIT 1;
                """
            )
            row = cur.fetchone()
            if row is None:
                raise ValueError("No load_log entries found — did the load run?")

            rows_loaded, rows_rejected = row
            if rows_loaded == 0:
                raise ValueError("Latest load inserted 0 rows.")

            reject_ratio = rows_rejected / (rows_loaded + rows_rejected)
            if reject_ratio > 0.05:
                raise ValueError(
                    f"Reject ratio {reject_ratio:.2%} exceeds the 5% threshold."
                )

            print(
                f"Load OK — {rows_loaded:,} loaded, "
                f"{rows_rejected:,} rejected ({reject_ratio:.2%})."
            )
    finally:
        conn.close()


with DAG(
    dag_id="pgpilot_pipeline",
    description="Ingest NYC taxi data, validate the load, then snapshot the database.",
    default_args=default_args,
    start_date=datetime(2026, 1, 1),
    schedule="@monthly",   # matches TLC's monthly data drops; also trigger by hand from the UI
    catchup=False,
    tags=["pgpilot", "pipeline"],
) as dag:

    load_taxi_data = BashOperator(
        task_id="load_taxi_data",
        bash_command=f"cd {PROJECT_DIR} && python scripts/load_data.py",
    )

    validate = PythonOperator(
        task_id="validate_load",
        python_callable=validate_load,
    )

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=(
            f"cd {PROJECT_DIR}/dbt && "
            "/opt/dbt-venv/bin/dbt run --profiles-dir . --target dev"
        ),
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=(
            f"cd {PROJECT_DIR}/dbt && "
            "/opt/dbt-venv/bin/dbt test --profiles-dir . --target dev"
        ),
    )

    backup_database = BashOperator(
        task_id="backup_database",
        # Trailing space is required: BashOperator treats a command ending in
        # .sh/.bash as a template *file* to load from the DAGs folder rather
        # than an inline command, since those are in its template_ext.
        bash_command=f"cd {PROJECT_DIR} && bash scripts/backup.sh ",
    )

    load_taxi_data >> validate >> dbt_run >> dbt_test >> backup_database
