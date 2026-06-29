# DBOps-Toolkit

## Getting Started — Running the Database

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