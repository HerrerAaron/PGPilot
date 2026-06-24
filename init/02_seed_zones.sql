-- Bulk-load the 265 TLC taxi zones from the official lookup table
-- (https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv).
COPY zones (location_id, borough, zone, service_zone)
FROM '/docker-entrypoint-initdb.d/taxi_zone_lookup.csv'
WITH (FORMAT csv, HEADER true);
