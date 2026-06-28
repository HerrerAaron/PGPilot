-- Lookup tables first so trips can reference them via foreign key.
CREATE TABLE vendors (
    vendor_id   INT PRIMARY KEY,
    vendor_name VARCHAR(50) NOT NULL
);

CREATE TABLE payment_types (
    payment_type_id      SMALLINT PRIMARY KEY,
    payment_description   VARCHAR(50) NOT NULL
);

-- TLC taxi zones (pickup/dropoff location reference). Seeded from
-- taxi_zone_lookup.csv in 02_seed_zones.sql.
CREATE TABLE zones (
    location_id  INT PRIMARY KEY,
    borough      VARCHAR(30) NOT NULL,
    zone         VARCHAR(100),
    service_zone VARCHAR(30)
);

CREATE TABLE trips (
    trip_id              SERIAL PRIMARY KEY,
    vendor_id             INT REFERENCES vendors(vendor_id),
    pickup_datetime       TIMESTAMP NOT NULL,
    dropoff_datetime      TIMESTAMP,
    passenger_count       SMALLINT,
    trip_distance         NUMERIC(8, 2),
    pickup_location_id    INT NOT NULL REFERENCES zones(location_id),
    dropoff_location_id   INT NOT NULL REFERENCES zones(location_id),
    fare_amount           NUMERIC(10, 2),
    tip_amount            NUMERIC(10, 2),
    total_amount          NUMERIC(10, 2),
    payment_type          SMALLINT REFERENCES payment_types(payment_type_id)
);

-- Seed lookup data based on the NYC TLC yellow taxi data dictionary
-- (https://www.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_yellow.pdf).
INSERT INTO vendors (vendor_id, vendor_name) VALUES
    (1, 'Creative Mobile Technologies, LLC'),
    (2, 'Curb Mobility, LLC'),
    (6, 'Myle Technologies Inc'),
    (7, 'Helix');

INSERT INTO payment_types (payment_type_id, payment_description) VALUES
    (0, 'Flex Fare trip'),
    (1, 'Credit card'),
    (2, 'Cash'),
    (3, 'No charge'),
    (4, 'Dispute'),
    (5, 'Unknown'),
    (6, 'Voided trip');
