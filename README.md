# PGPilot

## Getting Started: Running the Database

This project runs PostgreSQL 16 inside Docker, with schema initialization handled automatically on first start.

1. Copy `.env.example` to `.env` and set your own credentials:
   ```
   cp .env.example .env
   ```
2. Start the database:
   ```
   docker compose up -d
   ```
3. Verify the container is healthy:
   ```
   docker compose ps
   ```
4. Connect with `psql`:
   ```
   docker exec -it taxidb-postgres psql -U taxiuser -d taxidb
   ```

The schema in [init/01_schema.sql](init/01_schema.sql) (`vendors`, `payment_types`, `trips`) is applied automatically the first time the `pgdata` volume is created. If you change the schema after the volume already exists, drop the volume (`docker compose down -v`) and start again to re-run init scripts.

## Loading Data

[scripts/load_data.py](scripts/load_data.py) is a data engineering pipeline that ingests NYC TLC's public Yellow Taxi Trip Records (Parquet), cleans them, and bulk-loads them into Postgres. It turns a single month of data (~3.8M rows) into a realistic operational dataset for testing backup, monitoring, and performance-tuning workflows against.

**Running it:**

```
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python scripts/load_data.py
```

### Data cleaning

Several rows in the dataset were dropped due to containing logical errors that didn't make sense. Some of this criteria is provided below. 

| Rule | Reasoning |
|---|---|
| `fare_amount < 0` / `total_amount < 0` | A fare cannot be negative |
| `passenger_count = 0` | A completed fare implies at least one rider. Nulls are kept since they represent a real, documented "Flex Fare" trip type with no metered passenger count, not bad data. |
| `dropoff_datetime < pickup_datetime` | A trip cannot end before it starts |
| pickup outside the file's month | Catches a handful of mis-keyed dates (e.g. timestamps decades off) |
| null pickup/dropoff zone | Required to satisfy the FK into the `zones` lookup table |

On the April 2026 file: **3,831,240 rows read → 3,804,655 loaded, 26,585 rejected (0.69%)**, the bulk of which were negative fare/total amounts.

### Bulk loading

Rows are loaded with psycopg2's `copy_expert()` (Postgres's native `COPY ... FROM STDIN`) rather than row-by-row `INSERT`s. The entire cleaned dataset is staged into an in-memory CSV buffer and streamed to Postgres in one pass. Loading our data using this method is significantly more efficient than row-by-row inserts.

### Indexing and performance tuning

Indexes on `pickup_datetime` and `total_amount` are added **after** the bulk load, not before. Building them during the load would force Postgres to update both indexes on every inserted row, slowing down the process. Before/after performance is measured directly with `EXPLAIN ANALYZE` and logged to an `index_benchmark` table:

| Query | Before (Seq Scan) | After (Index Scan) | Speedup |
|---|---|---|---|
| 1-day `pickup_datetime` range | 152.70 ms | 27.96 ms | **5.5x** |
| `total_amount > 100` | 235.79 ms | 183.76 ms | **1.3x** |

The two indexes deliver very different speedups despite similarly selective queries. `pg_stats.correlation` explains why: `pickup_datetime` is `0.68` (rows were loaded in roughly chronological order, so matching rows sit on a small number of adjacent disk pages) versus `0.15` for `total_amount` (high-fare trips are scattered randomly across the table, so even a precise index still has to fetch from thousands of scattered pages). An index's payoff depends on how well the indexed column correlates with the table's physical row order, not just on how selective the query is.

## Backup & Recovery

[scripts/backup.sh](scripts/backup.sh) and [scripts/restore.sh](scripts/restore.sh) handle backing up and recovering the database via `pg_dump`/`pg_restore`, run through `docker exec` rather than requiring Postgres client tools installed on the host.

**Manual backup:**

```
./scripts/backup.sh
```

This dumps the database to a timestamped, compressed file in `backups/` (e.g. `taxidb_20260627_194658.dump`, ~72MB for the full ~3.8M-row dataset), logs the run to `logs/backup.log`, and deletes any `.dump` file older than 7 days.

**Manual restore:**

```
./scripts/restore.sh ./backups/taxidb_20260627_194658.dump
```

`restore.sh` uses `pg_restore --clean --if-exists`, so it safely drops and recreates only the objects present in the dump before reloading data. This includes any tables, indexes, or foreign keys that may have been dropped or modified since the backup was taken.

### Verified restore test

A backup script that's never had its restore path actually exercised is a common gap. This one was tested end-to-end, not just assumed to work:

1. Took a backup with the full dataset in place (3,804,655 rows in `trips`, 4 rows in `vendors`).
2. Dropped the `vendors` table entirely (`DROP TABLE vendors CASCADE`), which cascaded into removing the `trips_vendor_id_fkey` foreign key constraint as well.
3. Ran `restore.sh` against the prior backup.
4. Confirmed: `vendors` reappeared with all 4 rows, `trips_vendor_id_fkey` was recreated automatically, and `trips` still held exactly 3,804,655 rows throughout. The table that wasn't touched was never at risk, and the table that was dropped came back complete.

### Backup rotation

Verified directly: an 8-day-old dummy `.dump` file was deleted by the next `backup.sh` run, while two genuinely recent backups (minutes apart) were both retained. This confirms the `find ... -mtime +$BACKUP_RETAIN_DAYS -delete` rule only removes backups past the retention window, not recent ones.

### Log rotation

Backup rotation and log rotation are different things: the former prunes old `.dump` files, the latter manages the growth of `logs/backup.log` itself. Both `backup.sh` and `restore.sh` call a `rotate_log()` step before writing anything: once `backup.log` exceeds 1MB, it's archived to a timestamped `backup.log.<timestamp>.old` file and a fresh log starts; archived logs older than 30 days are then pruned the same way old backups are.

Verified directly: with the rotation threshold temporarily lowered, an over-threshold log file was archived correctly, and a 31-day-old archived copy was pruned on the next run while a freshly-written log was left untouched.

### Scheduling

The plan calls for scheduling these via Linux `cron`, which isn't available on native Windows (this project is developed on Windows + Docker Desktop). The intended crontab entries, for a Linux host or deployment target:

```
# Daily backup at 2am
0 2 * * * /path/to/DBOps-Toolkit/scripts/backup.sh

# Weekly summary every Sunday at 9am - last 20 lines of the backup log
0 9 * * 0 tail -n 20 /path/to/DBOps-Toolkit/logs/backup.log >> /path/to/DBOps-Toolkit/logs/weekly_summary.log
```

On this Windows dev machine, the closest equivalent is Windows Task Scheduler running the same script via Git Bash. This isn't implemented here, since the project's actual deployment target (and the skill the posting calls out) is Linux `cron`.

### Auditability

Every run of `load_data.py` records its own row counts, rejection counts, and timing breakdown (cleaning, `COPY`, indexing) to a `load_log` table, giving a persistent, queryable history of every load rather than relying on console output or memory.

## What Can Be Improved

- **Backup retention: Grandfather-Father-Son (GFS) tiering.** `backup.sh` currently uses a flat 7-day retention window. Real backup tooling typically uses GFS rotation instead: daily backups kept for a week, one weekly backup kept for a month, one monthly backup kept for a year, so long-term recoverability doesn't require keeping every daily snapshot forever. This wasn't implemented here because it solves a storage-growth problem that doesn't really exist at this project's scale, but it's the natural next step if this database were holding production-scale, long-lived data.