# PGPilot

>*A PostgreSQL operations toolkit built on real NYC taxi data, orchestrated with Apache Airflow and covering data ingestion, automated backups, health monitoring, and Continuous Integration (CI).*

![CI](https://github.com/HerrerAaron/PGPilot/actions/workflows/ci.yml/badge.svg)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.14-3776AB?logo=python&logoColor=white)
![Airflow](https://img.shields.io/badge/Apache_Airflow-3.3-017CEE?logo=apacheairflow&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-CI-2088FF?logo=github-actions&logoColor=white)

## About
PGPilot is a database operations toolkit built around a real-world NYC taxi dataset. The primary purpose of this project was to learn and build my skills in concepts commonly seen in DevOps roles. This includes things like containerization, continuous integration, monitoring and logging, and automation.

## Features

- Ingested and cleaned 3.8M rows of real NYC Yellow Taxi trip data, rejecting 26,585 rows (0.69%) based on documented business logic rules
- Bulk-loaded data using Postgres's native `COPY` command, then benchmarked index performance before and after with `EXPLAIN ANALYZE`
- Orchestrated with Apache Airflow: a `load → validate → backup` pipeline DAG with a fail-fast data-quality gate, plus a separate 15-minute health-monitoring DAG
- Automated `pg_dump` backups with 7-day rotation and log management, triggered by Airflow only after a load passes validation
- Verified restore integrity end-to-end: drops the `trips` table, restores from the dump, then confirms row counts, foreign key constraints, and indexes all match the pre-drop state
- Monitors four database health metrics via Postgres system views with threshold-based SMTP email alerting
- GitHub Actions CI pipeline that applies schema initialization scripts, loads synthetic data, and runs a full backup/restore cycle on every push

## Tech Stack

| Tool | Role |
|---|---|
| PostgreSQL 16 | Primary database |
| Python, pandas, psycopg2 | Data ingestion and monitoring pipeline |
| Apache Airflow | Pipeline orchestration and scheduling |
| Bash | Backup, restore, and log management scripts |
| Docker, Docker Compose | Containerization |
| GitHub Actions | CI pipeline |
| smtplib | SMTP email alerting |

## Architecture

```mermaid
graph TD
    PARQUET[NYC TLC Parquet] --> LOAD

    subgraph PIPELINE [pgpilot_pipeline DAG - monthly]
        LOAD[load_taxi_data] --> VALIDATE[validate_load] --> BACKUP[backup_database]
    end

    subgraph MONITORDAG [pgpilot_monitor DAG - every 15 min]
        MONITOR[run_health_monitor]
    end

    LOAD --> DB[(PostgreSQL 16\ntaxidb)]
    VALIDATE -.->|reads load_log| DB
    BACKUP -->|pg_dump| DUMP[backups/*.dump]
    MONITOR --> DB
    MONITOR -->|threshold breached| EMAIL[Email Alert]

    CI[GitHub Actions - on every push] -->|schema + synthetic data\nbackup + restore verify| DB
```

## Loading Data

[scripts/load_data.py](scripts/load_data.py) is a data engineering pipeline that ingests NYC TLC's public Yellow Taxi Trip Records, cleans them, and bulk-loads them into Postgres. It turns a single month of data (~3.8M rows) into a realistic operational dataset for testing backup, monitoring, and performance-tuning workflows.

### Data cleaning

Several rows in the dataset were dropped due to containing logical errors.

| Rule | Reasoning |
|---|---|
| `fare_amount < 0` / `total_amount < 0` | A fare cannot be negative |
| `passenger_count = 0` | A completed fare implies at least one rider. Nulls are kept since they represent a real, documented "Flex Fare" trip type with no metered passenger count, not bad data. |
| `dropoff_datetime < pickup_datetime` | A trip cannot end before it starts |
| pickup outside the file's month | Only focused on trips during April 2026 |
| null pickup/dropoff zone | Required to satisfy the FK into the `zones` lookup table |

On the April 2026 file: **3,831,240 rows read → 3,804,655 loaded, 26,585 rejected (0.69%)**, the bulk of which were negative fare/total amounts.

### Bulk loading

Rows are loaded with psycopg2's `copy_expert()` (Postgres's native `COPY ... FROM STDIN`) rather than row-by-row `INSERT`s. The entire cleaned dataset is staged into an in-memory CSV buffer and streamed to Postgres in one pass. This method is significantly more efficient than row-by-row inserts.

### Indexing and performance tuning

Indexes on `pickup_datetime` and `total_amount` are added **after** the bulk load, not before. Building them during the load would force Postgres to update both indexes on every inserted row, slowing down the process. Before/after performance is measured directly with `EXPLAIN ANALYZE` and logged to an `index_benchmark` table:

| Query | Before (Seq Scan) | After (Index Scan) | Speedup |
|---|---|---|---|
| `pickup_datetime` between date range | 152.70 ms | 27.96 ms | **5.5x** |
| `total_amount > 100` | 235.79 ms | 183.76 ms | **1.3x** |

The two indexes deliver very different speedups despite similarly selective queries. `pg_stats.correlation` explains why: `pickup_datetime` is `0.68` (i.e. rows were loaded in roughly chronological order, so matching rows sit on a small number of adjacent disk pages) versus `0.15` for `total_amount` (i.e. high-fare trips are scattered randomly across the table, so even a precise index still has to fetch from thousands of scattered pages). An index's payoff depends on how well the indexed column correlates with the table's physical row order, not just on how selective the query is.

### Auditability

Every run of `load_data.py` records its own row counts, rejection counts, and timing breakdown to a `load_log` table, giving a persistent, queryable history of every load rather than relying on console output or memory.

## Backup & Recovery

[scripts/backup.sh](scripts/backup.sh) and [scripts/restore.sh](scripts/restore.sh) handle backing up and recovering the database via `pg_dump`/`pg_restore`, run through `docker exec` rather than requiring Postgres client tools installed on the host.

**Manual backup:**

```
./scripts/backup.sh
```

This dumps the database to a timestamped, compressed file in `backups/` (e.g. `taxidb_20260627_194658.dump`), logs the run to `logs/backup.log`, and deletes any `.dump` file older than 7 days.

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

Backups are triggered by Apache Airflow's `pgpilot_pipeline` DAG ([airflow/dags/pgpilot_pipeline.py](airflow/dags/pgpilot_pipeline.py)) as the last step of a `load_taxi_data → validate_load → backup_database` dependency chain, running monthly to match how often the TLC actually publishes new data. `backup_database` invokes the existing, unmodified `backup.sh` through Airflow's `BashOperator` — the underlying `docker exec`/`pg_dump` mechanics haven't changed, only what triggers them. See [Orchestration](#orchestration) for why this replaced the original `cron` sidecar.

## Health Monitoring & Alerting

[scripts/monitor.py](scripts/monitor.py) polls the database every 15 minutes via Airflow's `pgpilot_monitor` DAG, collects four health metrics from Postgres's built-in system views, and sends an email alert if any metric crosses a warning or critical threshold.

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

### Persistent history

Every run inserts a row into `db_metrics` regardless of status, giving a queryable record of database health over time. This makes it possible to spot gradual trends that a single snapshot wouldn't reveal.

![db_metrics table](images/metrics_table.png)

*Monitoring results stored in the db_metrics table.*

### Alerting

When any metric crosses a threshold, an email is sent via SMTP with the metric values and status level. Thresholds are defined as named constants at the top of [scripts/monitor.py](scripts/monitor.py) and can be tuned to match the environment's normal baseline. `--dry-run` prints the alert body to the terminal instead of sending, making it safe to test without live email credentials.

![critical_warning_alert](images/email_critical_warning.png)

*Alert sent to email when critical threshold is surpassed.*

### Scheduling

The monitor runs every 15 minutes via Airflow's `pgpilot_monitor` DAG ([airflow/dags/pgpilot_monitor.py](airflow/dags/pgpilot_monitor.py)), a single-task DAG kept separate from the pipeline DAG since health checks need a much tighter cadence than a monthly data load. Each run's output is captured in the Airflow UI's per-task logs.

## Orchestration

[Apache Airflow](https://airflow.apache.org/) replaces the original `cron` sidecar. Two DAGs wrap the existing scripts as tasks — [pgpilot_pipeline.py](airflow/dags/pgpilot_pipeline.py) and [pgpilot_monitor.py](airflow/dags/pgpilot_monitor.py) — without rewriting any of `load_data.py`, `backup.sh`, or `monitor.py`.

**`pgpilot_pipeline`** runs monthly, matching TLC's data-drop cadence, as a real dependency chain: `load_taxi_data → validate_load → backup_database`. `validate_load` reads the latest `load_log` row and fails the DAG if the load inserted zero rows or the rejection ratio exceeds 5%, so a broken load is never backed up.

**`pgpilot_monitor`** runs independently every 15 minutes, since health checks need a tighter cadence than a monthly load.

### Design choices

- **LocalExecutor**, not the official Compose file's default `CeleryExecutor` — single-machine task execution needs no message broker or worker pool for local development.
- **A separate metadata database** (`airflow-db`) tracks DAG runs and task state, entirely distinct from `taxidb`. Confusing the two is the most common Airflow setup mistake.
- **A custom image** ([Dockerfile.airflow](Dockerfile.airflow)) adds the same Python dependencies the scripts already need, plus the `docker` CLI so `backup.sh`'s `docker exec` calls keep working unmodified from inside the Airflow container.
- **No standalone daily backup DAG.** Data only changes on a monthly load, so a backup gated on a validated load is more meaningful than a fixed 2am snapshot of an unchanged database.

### Running it

```
docker compose up -d --build
```

Open `http://localhost:8080` (`airflow` / `airflow`, set in `.env`), unpause `pgpilot_pipeline` and `pgpilot_monitor`, and trigger a run from the UI. Every task's logs are captured per run — a direct upgrade over `cron`'s flat log files.

## Continuous Integration

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every push and pull request. It spins up a real Postgres 16 instance, builds the database schema from `/init`, loads 1,000 synthetic rows, runs the health monitor in dry-run mode, and runs a full backup and restore verification cycle.

### Synthetic data for CI

The original dataset is a 600MB parquet file that is gitignored. `load_data.py` generates synthetic rows deterministically and inserts them through the same COPY pipeline, so CI exercises the real load path without committing large files to the repo.

### Backup and restore verification

After backup.sh produces a dump, the pipeline drops the trips table, restores from the dump, then confirms that row counts, foreign key constraints, and indexes all match the pre-drop state.

## What I Learned

**PostgreSQL Internals**: 
- How `pg_stat_activity`, `pg_stat_user_tables`, and `pg_database_size()` expose the live database state
- Why `EXPLAIN ANALYZE` output varies based on physical row order (`pg_stats.correlation`)
- How dead tuples accumulate and why `VACUUM` matters for query performance

**Data Engineering**:
- Cleaning a real-world dataset with non-obvious rules (e.g. keeping null passenger counts)
- Why `COPY ... FROM STDIN` is faster than row-by-row inserts
- Why indexes are built after a bulk load, not before

**Backup and Recovery**:
- Using `pg_dump -Fc` (custom format) for compressed, restore-friendly dumps vs plain SQL exports
- `pg_restore --clean --if-exists` for safe restores that handle partially dropped schemas
- Separating backup rotation from log rotation since they have different retention windows and failure modes

**Docker and Containerization**:
- The sidecar pattern for running an auxiliary process (`cron`, then Airflow) alongside a database without modifying the database image
- Mounting the Docker socket so a container can exec into a sibling container
- How Docker volumes persist data independently of container lifecycle

**Orchestration**:
- DAGs, operators, and explicit task dependencies as a replacement for implicit ordering in a cron schedule
- Building a fail-fast data-quality gate (`validate_load`) that blocks a downstream task when upstream output looks wrong
- LocalExecutor vs CeleryExecutor and when a message broker is actually necessary
- Keeping an orchestrator's own metadata database cleanly separate from the data it orchestrates

**Observability**:
- The difference between polling-based monitoring and event-driven alerting, and where polling breaks down
- Storing metric history in a table to surface trends that a single snapshot misses
- Using `--dry-run` flags to test alert logic safely in any environment

**CI**:
- Why environment parity matters (i.e. code that passes locally but fails in CI usually means an undeclared dependency)
- Client-side vs server-side `COPY` and why they behave differently across environments
- Using `CI=true` as a branch point to adapt scripts without duplicating logic


## What Can Be Improved

- **Backup retention (GFS tiering).** `backup.sh` uses a flat 7-day window. Production systems typically use Grandfather-Father-Son (GFS) rotation (i.e. daily backups for a week, weekly for a month, monthly for a year) so long-term recoverability doesn't require keeping every daily snapshot indefinitely. This wasn't implemented here since the storage-growth problem doesn't exist at this project's scale.

- **Polling-based monitoring has a blind spot.** `monitor.py` captures a snapshot every 15 minutes, so an incident that starts and resolves between checks goes undetected. In production this is addressed by shortening the interval (e.g. Prometheus scrapes every 15–30 seconds) or replacing polling with event-driven alerting entirely. At this project's scale the trade-off is acceptable, but it's worth understanding the gap.

- **Schema migrations.** The `init/` scripts only run on first volume creation, which works for a clean setup but doesn't support evolving the schema without dropping all data. A migrations tool like Flyway or Alembic would manage incremental schema changes safely in a long-lived production database.

- **LocalExecutor doesn't scale past one machine.** Airflow tasks run in parallel via multiprocessing on a single host, which is correct for local development but caps throughput at one machine's resources. Production Airflow deployments typically use `CeleryExecutor` or `KubernetesExecutor` to distribute tasks across workers.

## Getting Started

1. Copy `.env.example` to `.env`, fill in your credentials, and generate an Airflow Fernet key:
   ```
   cp .env.example .env
   python -c "import os, base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
   ```
   Paste the generated value into `.env` as `FERNET_KEY`.
2. Build and start the database and Airflow:
   ```
   docker compose up -d --build
   ```
3. Verify all containers are healthy:
   ```
   docker compose ps
   ```
4. Connect with `psql`:
   ```
   docker exec -it taxidb-postgres psql -U taxiuser -d taxidb
   ```

The schema in [init/01_schema.sql](init/01_schema.sql) is applied automatically the first time the `pgdata` volume is created. If you change the schema after the volume already exists, drop the volume (`docker compose down -v`) and start again.

Airflow's UI is at `http://localhost:8080` (`airflow` / `airflow`, from `.env`). DAGs start paused — unpause `pgpilot_pipeline` and `pgpilot_monitor` and trigger a run from the UI. See [Orchestration](#orchestration) for details.

**Load data** — download the [April 2026 NYC TLC Yellow Taxi parquet file](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page) into `orig_data/`, then:

```
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python scripts/load_data.py
```

**Run the health monitor manually:**

```
python scripts/monitor.py --dry-run
```

Remove `--dry-run` to send a real email alert. Requires `ALERT_EMAIL`, `SMTP_USER`, and `SMTP_PASSWORD` to be set in `.env`.

**Run a manual backup:**

```
./scripts/backup.sh
```

**Restore from a backup:**

```
./scripts/restore.sh ./backups/<filename>.dump
```

## Author

**Aaron Herrera** — [LinkedIn](https://www.linkedin.com/in/aaronherrera4/)
