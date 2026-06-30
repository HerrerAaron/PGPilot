import io
import os
import re
import time

import pandas as pd
import psycopg2
from dotenv import load_dotenv

load_dotenv()

POSTGRES_PORT = 5432

DB_CONFIG = {
    "host": "localhost",
    "port": POSTGRES_PORT,
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
}

PARQUET_FILE = "orig_data/yellow_tripdata_2026-04.parquet"

TRIP_COLUMNS = [
    "vendor_id",
    "pickup_datetime",
    "dropoff_datetime",
    "passenger_count",
    "trip_distance",
    "pickup_location_id",
    "dropoff_location_id",
    "fare_amount",
    "tip_amount",
    "total_amount",
    "payment_type",
]

# Representative queries for the pickup_datetime / total_amount indexes,
# benchmarked once before the indexes exist and once after.
BENCHMARK_QUERIES = {
    "pickup_datetime_range": "SELECT count(*) FROM trips WHERE pickup_datetime BETWEEN '2026-04-15' AND '2026-04-16'",
    "total_amount_threshold": "SELECT count(*) FROM trips WHERE total_amount > 100",
}


def load_and_clean(path):
    df = pd.read_parquet(path)
    rows_read = len(df)

    df = df.rename(columns={
        "VendorID": "vendor_id",
        "tpep_pickup_datetime": "pickup_datetime",
        "tpep_dropoff_datetime": "dropoff_datetime",
        "PULocationID": "pickup_location_id",
        "DOLocationID": "dropoff_location_id",
    })
    df = df[TRIP_COLUMNS]

    # Restrict to the calendar month the file is actually for, dropping the
    # handful of mis-keyed timestamps (e.g. years off) seen in this dataset.
    # derive the file's month from the most common pickup month, then compute its bounds
    month_start = df["pickup_datetime"].dt.to_period("M").mode()[0].start_time
    month_end = month_start + pd.offsets.MonthBegin(1)

    valid = (
        df["pickup_datetime"].notna()
        & (df["fare_amount"] >= 0)
        & (df["total_amount"] >= 0)
        # passenger_count is null for legitimate Flex Fare trips (payment_type
        # 0) - keep nulls; 0 is a contradiction (a fare implies a rider)
        & (df["passenger_count"].isna() | (df["passenger_count"] >= 1))
        & (df["dropoff_datetime"] >= df["pickup_datetime"])
        & (df["pickup_datetime"] >= month_start)
        & (df["pickup_datetime"] < month_end)
        & df["pickup_location_id"].notna()
        & df["dropoff_location_id"].notna()
    )
    df = df[valid]

    # SMALLINT column - avoid "1.0" showing up once written to CSV.
    df["passenger_count"] = df["passenger_count"].astype("Int64")

    rows_clean = len(df)
    return df, rows_read, rows_clean


def bulk_insert(conn, df):
    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False, na_rep="")
    buffer.seek(0)

    columns = ", ".join(TRIP_COLUMNS)
    copy_sql = f"COPY trips ({columns}) FROM STDIN WITH (FORMAT csv, NULL '')"

    start = time.perf_counter()
    with conn.cursor() as cur:
        cur.copy_expert(copy_sql, buffer)
    conn.commit()
    return time.perf_counter() - start

def analyze_table(conn):
    with conn.cursor() as cur:
        cur.execute("ANALYZE trips;")
    conn.commit()


def create_indexes(conn):
    with conn.cursor() as cur:
        cur.execute("CREATE INDEX IF NOT EXISTS idx_trips_pickup_datetime ON trips (pickup_datetime);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_trips_total_amount ON trips (total_amount);")
    conn.commit()


def explain_query(conn, sql):
    with conn.cursor() as cur:
        cur.execute("EXPLAIN ANALYZE " + sql)
        plan_text = "\n".join(row[0] for row in cur.fetchall())

    execution_time_ms = float(re.search(r"Execution Time: ([\d.]+) ms", plan_text).group(1))
    scan_type = "Index Scan" if "Index Scan" in plan_text else "Seq Scan"
    return execution_time_ms, scan_type, plan_text


def benchmark_queries(conn, phase):
    results = []
    with conn.cursor() as cur:
        for label, sql in BENCHMARK_QUERIES.items():
            execution_time_ms, scan_type, plan_text = explain_query(conn, sql)
            print(f"--- {label} ({phase}) ---\n{plan_text}\n")
            cur.execute(
                """
                INSERT INTO index_benchmark (query_label, phase, scan_type, execution_time_ms)
                VALUES (%s, %s, %s, %s)
                """,
                (label, phase, scan_type, execution_time_ms),
            )
            results.append((label, scan_type, execution_time_ms))
    conn.commit()
    return results


def log_run(conn, source_file, rows_loaded, rows_rejected, copy_duration, duration_seconds):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO load_log
                (source_file, rows_loaded, rows_rejected, copy_duration_seconds, duration_seconds)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (source_file, rows_loaded, rows_rejected, copy_duration, duration_seconds),
        )
    conn.commit()


def main():
    start = time.perf_counter()
    df, rows_read, rows_clean = load_and_clean(PARQUET_FILE)
    rows_rejected = rows_read - rows_clean
    clean_duration = time.perf_counter() - start

    conn = psycopg2.connect(**DB_CONFIG)
    try:
        copy_duration = bulk_insert(conn, df)

        # Stats need to be fresh before benchmarking "before" too, so the
        # only variable between before/after is the index itself.
        analyze_table(conn)
        before = benchmark_queries(conn, "before")

        index_start = time.perf_counter()
        create_indexes(conn)
        analyze_table(conn)
        index_duration = time.perf_counter() - index_start

        after = benchmark_queries(conn, "after")

        duration = time.perf_counter() - start
        log_run(conn, PARQUET_FILE, rows_clean, rows_rejected, copy_duration, duration)
    finally:
        conn.close()

    print(
        f"read={rows_read} rejected={rows_rejected} loaded={rows_clean} "
        f"clean={clean_duration:.2f}s copy={copy_duration:.2f}s "
        f"index={index_duration:.2f}s total={duration:.2f}s"
    )
    for (label, scan_type, ms), (_, after_scan_type, after_ms) in zip(before, after):
        print(f"{label}: before={scan_type} {ms:.2f}ms  after={after_scan_type} {after_ms:.2f}ms")


if __name__ == "__main__":
    main()
