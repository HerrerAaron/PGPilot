-- Stores data on DB metrics such as longest query time length, size, active
-- connections, and table bloat. Will help with tracking database health 
-- conditions over time. 
create TABLE db_metrics (
    id                  SERIAL PRIMARY KEY,
    checked_at          TIMESTAMP DEFAULT NOW(),
    db_size_mb          NUMERIC,
    active_connections  INT,
    longest_query_sec   NUMERIC,
    table_bloat_pct     NUMERIC,
    status              VARCHAR(20)
);