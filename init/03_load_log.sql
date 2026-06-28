-- Records one row per load_data.py run, for auditing data pipeline history.
CREATE TABLE load_log (
    id                    SERIAL PRIMARY KEY,
    run_at                TIMESTAMP DEFAULT NOW(),
    source_file           VARCHAR(255) NOT NULL,
    rows_loaded           INT NOT NULL,
    rows_rejected         INT NOT NULL,
    copy_duration_seconds NUMERIC(10, 2) NOT NULL,
    duration_seconds      NUMERIC(10, 2) NOT NULL
);
