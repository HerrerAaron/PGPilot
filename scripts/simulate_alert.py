import subprocess
import sys
import threading
import time

import psycopg2
from dotenv import load_dotenv
import os

load_dotenv()

POSTGRES_PORT = 5432
SLEEP_DURATION_SEC = 90
MONITOR_TRIGGER_SEC = 65

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "localhost"),
    "port": POSTGRES_PORT,
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
}


def run_slow_query():
    conn = psycopg2.connect(**DB_CONFIG)
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT pg_sleep({SLEEP_DURATION_SEC})")
    except Exception:
        pass
    finally:
        conn.close()


def main():
    print(f"Starting {SLEEP_DURATION_SEC}s sleep query to push longest_query_sec above the critical threshold (60s)...")
    t = threading.Thread(target=run_slow_query, daemon=True)
    t.start()

    print(f"Waiting {MONITOR_TRIGGER_SEC} seconds for the query to exceed the critical threshold...")
    time.sleep(MONITOR_TRIGGER_SEC)

    print("\nRunning monitor.py:\n")
    # subprocess.run([sys.executable, "scripts/monitor.py", "--dry-run"]) # dry-run
    subprocess.run([sys.executable, "scripts/monitor.py"]) # send to email

    print("\nSimulation complete. Background query terminates on script exit.")


if __name__ == "__main__":
    main()
