-- Lookup tables first so trips can reference them via foreign key.
CREATE TABLE vendors (
    vendor_id   INT PRIMARY KEY,
    vendor_name VARCHAR(50) NOT NULL
);

CREATE TABLE payment_types (
    payment_type_id   SMALLINT PRIMARY KEY,
    payment_description VARCHAR(50) NOT NULL
);

CREATE TABLE trips (
    trip_id          SERIAL PRIMARY KEY,
    vendor_id        INT REFERENCES vendors(vendor_id),
    pickup_datetime  TIMESTAMP NOT NULL,
    dropoff_datetime TIMESTAMP,
    passenger_count  SMALLINT,
    trip_distance    NUMERIC(8, 2),
    fare_amount      NUMERIC(10, 2),
    tip_amount       NUMERIC(10, 2),
    total_amount     NUMERIC(10, 2),
    payment_type     SMALLINT REFERENCES payment_types(payment_type_id)
);

-- Seed lookup data based on the NYC TLC data dictionary.
INSERT INTO vendors (vendor_id, vendor_name) VALUES
    (1, 'Creative Mobile Technologies'),
    (2, 'VeriFone Inc.');

INSERT INTO payment_types (payment_type_id, payment_description) VALUES
    (1, 'Credit card'),
    (2, 'Cash'),
    (3, 'No charge'),
    (4, 'Dispute'),
    (5, 'Unknown'),
    (6, 'Voided trip');
