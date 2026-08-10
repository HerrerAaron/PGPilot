from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT_DIR = "/opt/pgpilot"

with DAG(
    dag_id="pgpilot_monitor",
    description="Poll database health metrics and alert on threshold breaches.",
    start_date=datetime(2026, 1, 1),
    schedule="*/15 * * * *",   # every 15 minutes, matching the v1 cron cadence
    catchup=False,
    default_args={"retries": 1, "retry_delay": timedelta(minutes=1)},
    tags=["pgpilot", "monitoring"],
) as dag:

    run_health_monitor = BashOperator(
        task_id="run_health_monitor",
        # Start with --dry-run while testing so no real emails go out;
        # drop the flag once you've confirmed the alert path works.
        bash_command=f"cd {PROJECT_DIR} && python scripts/monitor.py --dry-run",
    )
