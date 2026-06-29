-- Records EXPLAIN ANALYZE results for representative queries, run once before
-- the pickup_datetime/total_amount indexes exist and once after, so the
-- performance improvement from indexing can be shown with real numbers.
CREATE TABLE index_benchmark (
    id                 SERIAL PRIMARY KEY,
    run_at             TIMESTAMP DEFAULT NOW(),
    query_label        VARCHAR(50) NOT NULL,
    phase              VARCHAR(10) NOT NULL,
    scan_type          VARCHAR(20) NOT NULL,
    execution_time_ms  NUMERIC(10, 2) NOT NULL
);
