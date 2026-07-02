# PGPilot

![CI](https://github.com/HerrerAaron/PGPilot/actions/workflows/ci.yml/badge.svg)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)

PGPilot is a database operations toolkit built around a real-world NYC taxi dataset. It covers the full operational lifecycle of a PostgreSQL database: ingesting and cleaning 3.8M rows of raw trip data, automating backups with rotation and log management, monitoring database health with threshold-based email alerting, and validating everything end-to-end in a CI pipeline on every push.

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

Tested end-to-end: dropped the `vendors` table entirely (cascading its foreign key into `trips`), then ran `restore.sh` against a prior backup. Both the table and the FK constraint were recreated automatically, and row counts matched exactly.

### Backup rotation

`.dump` files older than 7 days are deleted automatically on each `backup.sh` run via `find ... -mtime +7 -delete`. Recent backups are never touched.

### Log rotation

Backup rotation (pruning old `.dump` files) and log rotation (managing `backup.log` growth) are handled separately. Once `backup.log` exceeds 1MB, it's archived to a timestamped `.old` file and a fresh log starts. Archived logs older than 30 days are pruned on the next run.

### Scheduling

Native Windows has no `cron`, so scheduling runs in a dedicated `scheduler` container instead ([scheduler/Dockerfile](scheduler/Dockerfile), [scheduler/crontab](scheduler/crontab)). It's a small sidecar, separate from the database container, whose only job is running `cron` and triggering the existing, unmodified `backup.sh`/`restore.sh` on a real schedule:

```
# Daily backup at 2am
0 2 * * * root /app/scripts/backup.sh >> /app/logs/cron.log 2>&1

# Weekly summary every Sunday at 9am - last 20 lines of the backup log
0 9 * * 0 root tail -n 20 /app/logs/backup.log >> /app/logs/weekly_summary.log 2>&1
```

This works identically on any host (Windows, Mac, Linux) since `cron` runs inside the container, not on the host OS. The sidecar mounts the host's Docker socket and the project directory, so it can `docker exec` into `taxidb-postgres` exactly like a person running `backup.sh` manually would, and any backups/logs it produces land in the real `backups/`/`logs/` directories on the host, not trapped inside the container. Verified directly: manually triggered `backup.sh` and `restore.sh` through the sidecar (`docker exec taxidb-scheduler /app/scripts/backup.sh`), confirmed the resulting `.dump` file appeared on the host filesystem, and confirmed `crontab -l` inside the container shows the real schedule loaded and ready to fire on its own.

### Auditability

Every run of `load_data.py` records its own row counts, rejection counts, and timing breakdown to a `load_log` table, giving a persistent, queryable history of every load rather than relying on console output or memory.

## Health Monitoring & Alerting

[scripts/monitor.py](scripts/monitor.py) polls the database every 15 minutes via the `scheduler` sidecar, collects four health metrics from Postgres's built-in system views, and sends an email alert if any metric crosses a warning or critical threshold.

**Manual run:**

```
python scripts/monitor.py
```

Use `--dry-run` to verify the full pipeline without sending email:

```
python scripts/monitor.py --dry-run
```

### What is monitored

| Metric | Why it matters |
|---|---|
| `db_size_mb` | Catches runaway data growth before it fills the disk |
| `active_connections` | Postgres has a hard connection cap; exhausting it refuses all new connections |
| `longest_query_sec` | A query running longer than expected is usually blocking others or missing an index |
| `table_bloat_pct` | Dead rows accumulate until VACUUM reclaims them; high bloat degrades query performance |

![db_metrics table](images/metrics_table.png)
*Monitoring results stored in the db_metrics table.*

### Persistent history

Every run inserts a row into `db_metrics` regardless of status, giving a queryable record of database health over time. This makes it possible to spot gradual trends that a single snapshot wouldn't reveal.

### Alerting

When any metric crosses a threshold, an email is sent via SMTP with the metric values and status level. Thresholds are defined as named constants at the top of [scripts/monitor.py](scripts/monitor.py) and can be tuned to match the environment's normal baseline. `--dry-run` prints the alert body to the terminal instead of sending, making it safe to test without live email credentials.

![critical_warning_alert](images/email_critical_warning.png)
*Alert for critical result.*

### Scheduling

The monitor runs every 15 minutes via the existing `scheduler` sidecar alongside the backup jobs. No additional infrastructure is needed. Output from each automated run is appended to `logs/monitor.log`.

## CI/CD

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every push and pull request. It spins up a real Postgres 16 instance, applies every schema migration from `init/`, loads 1,000 synthetic rows, runs the health monitor in dry-run mode, and exercises the backup path — all in a clean environment with no local state.

### Why this matters

In a DevOps role, you can't rely on manual testing for database changes. A schema migration that looks fine locally might break against a fresh database if an init script runs in the wrong order, or a script that works on your machine might silently assume a file that isn't committed. CI catches both of these automatically on every push, before any issue reaches a teammate or a deployment.

### Synthetic data for CI

The original dataset is a 600MB parquet file that lives in `orig_data/` and is gitignored. CI can't use it. Instead, `load_data.py --sample N` generates N lightweight synthetic rows deterministically (seeded with `random.seed(42)`) and inserts them the same way the real pipeline does — through `COPY ... FROM STDIN`. This means the CI load step exercises the actual insert path, index creation, and benchmark logging, just with smaller data.

### Backup and restore verification

The CI pipeline doesn't just run a backup — it verifies the backup is actually usable. After `backup.sh` produces a dump, the workflow drops the `trips` table entirely, restores from the dump, and queries the row count to confirm the data came back. A backup that can't restore is worthless, so testing the full cycle is more meaningful than testing either step in isolation.

Both `backup.sh` and `restore.sh` detect the `CI=true` environment variable that GitHub Actions sets automatically and call `pg_dump`/`pg_restore` directly instead of going through `docker exec`. The logic is the same; only the transport layer adapts to the environment.

## What I Learned

**PostgreSQL internals** — how `pg_stat_activity`, `pg_stat_user_tables`, and `pg_database_size()` expose live database state; why `EXPLAIN ANALYZE` output varies based on physical row order (`pg_stats.correlation`); how dead tuples accumulate and why `VACUUM` matters for query performance.

**Data engineering** — cleaning a real-world dataset with non-obvious rules (keeping null passenger counts, filtering by derived month bounds); why `COPY ... FROM STDIN` is orders of magnitude faster than row-by-row inserts; why indexes are built after a bulk load, not before.

**Backup and recovery** — using `pg_dump -Fc` (custom format) vs plain SQL; `pg_restore --clean --if-exists` for safe incremental restores; separating backup rotation from log rotation since they have different retention windows and failure modes.

**Docker and containerization** — the sidecar pattern for running `cron` alongside a database without modifying the database image; mounting the Docker socket so a container can exec into a sibling container; how Docker volumes persist data independently of container lifecycle.

**Observability** — the difference between polling-based monitoring and event-driven alerting, and where polling breaks down; storing metric history in a table to surface trends that a single snapshot misses; using `--dry-run` flags to test alert logic safely in any environment.

**CI/CD** — why environment parity matters (code passing locally but failing in CI usually means an undeclared dependency); client-side vs server-side `COPY` and why they behave differently across environments; using `CI=true` as a branch point to adapt scripts without duplicating them.

## What Can Be Improved

- **Backup retention: Grandfather-Father-Son (GFS) tiering.** `backup.sh` currently uses a flat 7-day retention window. Real backup tooling typically uses GFS rotation instead: daily backups kept for a week, one weekly backup kept for a month, one monthly backup kept for a year, so long-term recoverability doesn't require keeping every daily snapshot forever. This wasn't implemented here because it solves a storage-growth problem that doesn't really exist at this project's scale, but it's the natural next step if this database were holding production-scale, long-lived data.

- **Polling-based monitoring has a blind spot.** `monitor.py` captures a snapshot at the moment it runs — an incident that starts and resolves between two 15-minute checks goes completely undetected. In production this is addressed by shortening the interval (Prometheus scrapes every 15–30 seconds) or replacing polling with event-driven alerting entirely. At this project's scale the trade-off is acceptable, but it's worth understanding the gap.

- **Scheduled backups depend on the machine being on.** The `scheduler` container's `cron` job only fires if the container, Docker Desktop, and the physical machine are all running at 2am. This is correct behavior for an always-on production server, which is what the schedule is modeling, but on a personal dev machine that sleeps or shuts down overnight, that night's backup is simply skipped, since standard `cron` doesn't retroactively run missed jobs. A production deployment on an always-on host wouldn't have this gap; mitigations for a personal machine would include also running a backup on container startup, or configuring Windows to wake the machine for scheduled tasks.