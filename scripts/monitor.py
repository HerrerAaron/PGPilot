import argparse
import os
import smtplib
from email.message import EmailMessage

import psycopg2
from dotenv import load_dotenv

load_dotenv()

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": 5432,
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
}

ALERT_EMAIL = os.environ.get("ALERT_EMAIL")
SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", 587))
SMTP_USER = os.environ.get("SMTP_USER")
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD")

# Query the database and return a dict of health metrics
def collect_metrics(conn):
    metrics = {}
    with conn.cursor() as cur:
        cur.execute("SELECT round(pg_database_size(current_database()) / 1024.0 / 1024.0, 2)")
        metrics["db_size_mb"] = cur.fetchone()[0]

        cur.execute("SELECT count(*) FROM pg_stat_activity WHERE state = 'active'")
        metrics["active_connections"] = cur.fetchone()[0]

        cur.execute(
            "SELECT coalesce(round(extract(epoch from max(now() - query_start))::numeric, 2), 0)"
            " FROM pg_stat_activity WHERE state = 'active' AND query_start IS NOT NULL"
        )
        metrics["longest_query_sec"] = cur.fetchone()[0]

        cur.execute(
            "SELECT coalesce(round(100.0 * sum(n_dead_tup) / nullif(sum(n_live_tup + n_dead_tup), 0), 2), 0)"
            " FROM pg_stat_user_tables"
        )
        metrics["table_bloat_pct"] = cur.fetchone()[0]

    return metrics

# Return "ok", "warning", or "critical" based on metric threshold
def evaluate_status(metrics):
    if (
        metrics["db_size_mb"] > 2000
        or metrics["active_connections"] > 90
        or metrics["longest_query_sec"] > 60
        or metrics["table_bloat_pct"] > 50
    ):
        return "critical"
    if (
        metrics["db_size_mb"] > 500
        or metrics["active_connections"] > 50
        or metrics["longest_query_sec"] > 30
        or metrics["table_bloat_pct"] > 20
    ):
        return "warning"
    return "ok"


def save_metrics(conn, metrics, status):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO db_metrics
                (db_size_mb, active_connections, longest_query_sec, table_bloat_pct, status)
            VALUES (%(db_size_mb)s, %(active_connections)s, %(longest_query_sec)s, %(table_bloat_pct)s, %(status)s)
            """,
            {**metrics, "status": status},
        )
    conn.commit()


def send_alert(subject, body, dry_run=False):
    if dry_run:
        print(f"[dry-run] Would send alert: {subject}\n{body}")
        return

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_USER
    msg["To"] = ALERT_EMAIL
    msg.set_content(body)

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as smtp:
        smtp.starttls()
        smtp.login(SMTP_USER, SMTP_PASSWORD)
        smtp.send_message(msg)

    print(f"Alert sent: {subject}")


def main():
    parser = argparse.ArgumentParser(description="Monitor database health.")
    parser.add_argument("--dry-run", action="store_true", help="Print alerts without sending email.")
    args = parser.parse_args()

    conn = psycopg2.connect(**DB_CONFIG)
    try:
        metrics = collect_metrics(conn)
        status = evaluate_status(metrics)
        save_metrics(conn, metrics, status)

        if status != "ok":
            body = (
                f"Status: {status.upper()}\n\n"
                f"DB size:            {metrics['db_size_mb']} MB\n"
                f"Active connections: {metrics['active_connections']}\n"
                f"Longest query:      {metrics['longest_query_sec']} sec\n"
                f"Table bloat:        {metrics['table_bloat_pct']}%\n"
            )
            send_alert(
                subject=f"[PGPilot] Database status: {status}",
                body=body,
                dry_run=args.dry_run,
            )
        else:
            print(f"Status: {status} — {metrics}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
